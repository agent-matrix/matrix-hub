#!/usr/bin/env bash
# examples/register_watsonx_local_via_hub.sh
# Push an inline manifest to Matrix Hub, then trigger /remotes/sync.
# Fixes:
#  - Tool is Type MCP, has URL + input_schema
#  - Ensures at least one good remote exists
#  - Removes known-bad local 127.0.0.1:8000/matrix/index.json remote to avoid 404 noise

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# --- Load env if present (HUB_URL, API_TOKEN, MATRIX_REMOTES, etc.) ---
ENV_FILE="${ENV_FILE:-${ROOT_DIR}/.env}"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a; . "$ENV_FILE"; set +a
fi

# --- Config (override via env as needed) ---
HUB_URL="${HUB_URL:-http://127.0.0.1:7300}"
API_TOKEN="${API_TOKEN:-}"     # optional; if blank, we skip auth header

# Entity identity (shows up as a federated “Gateway”)
ID="${ID:-code}"
VER="${VER:-0.1.0}"
NAME="${NAME:-Code}"
DESC="${DESC:-Local Watsonx MCP}"

# Your Watsonx FastMCP server SSE endpoint (use /messages/ if you proxy that way)
SERVER_URL="${SERVER_URL:-http://127.0.0.1:6288/sse}"

# TOOL: Make it Type MCP, give it the URL, and a real input_schema
TOOL_ID="${TOOL_ID:-code-chat}"
TOOL_NAME="${TOOL_NAME:-code-chat}"
TOOL_DESC="${TOOL_DESC:-Chat with IBM watsonx.ai (accepts str or int)}"

# Remote management
DEFAULT_REMOTE="${DEFAULT_REMOTE:-https://raw.githubusercontent.com/agent-matrix/catalog/main/index.json}"
REMOVE_NOISY_LOCAL="${REMOVE_NOISY_LOCAL:-1}"  # 1 = try to remove 127.0.0.1:8000/matrix/index.json
NOISY_LOCAL_URL="${NOISY_LOCAL_URL:-http://127.0.0.1:8000/matrix/index.json}"

# Derived (readonly)
ENTITY_UID="mcp_server:${ID}@${VER}"

# --- Auth header only if API_TOKEN is present ---
auth_flags=()
if [[ -n "$API_TOKEN" ]]; then
  auth_flags=(-H "Authorization: Bearer ${API_TOKEN}")
fi

# --- Helpers ---
log()  { printf "\033[1;34m➤\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m!\033[0m %s\n" "$*"; }
die()  { printf "\033[1;31m✖\033[0m %s\n" "$*" >&2; exit 1; }

require_bin() { command -v "$1" >/dev/null 2>&1 || die "$1 not found in PATH"; }
require_bin curl
require_bin jq

TMP_MANIFEST="$(mktemp -t wx_manifest.XXXXXX.json)"
trap 'rm -f "$TMP_MANIFEST"' EXIT

# --- Build inline manifest (TOOL is MCP + URL + input_schema) ---
jq -n \
  --arg id        "$ID" \
  --arg name      "$NAME" \
  --arg ver       "$VER" \
  --arg desc      "$DESC" \
  --arg url       "$SERVER_URL" \
  --arg tool_id   "$TOOL_ID" \
  --arg tool_name "$TOOL_NAME" \
  --arg tool_desc "$TOOL_DESC" \
'{
  schema_version: 1,
  type: "mcp_server",
  id: $id,
  name: $name,
  version: $ver,
  summary: $desc,
  description: $desc,
  mcp_registration: {
    tool: {
      id: $tool_id,
      name: $tool_name,
      description: $tool_desc,
      integration_type: "MCP",
      url: $url,
      input_schema: {
        title: "chatArguments",
        type: "object",
        properties: {
          query: {
            title: "Query",
            anyOf: [{type:"string"}, {type:"integer"}]
          }
        },
        required: ["query"]
      }
    },
    resources: [],
    prompts: [],
    server: {
      name: $name,
      description: $desc,
      transport: "SSE",
      url: $url,
      associated_tools:     [$tool_id],
      associated_resources: [],
      associated_prompts:   []
    }
  }
}' > "$TMP_MANIFEST"

# Build /catalog/install payload
PAYLOAD="$(jq -n \
  --arg uid "$ENTITY_UID" \
  --arg target "./" \
  --slurpfile manifest "$TMP_MANIFEST" \
  '{id:$uid, target:$target, manifest:$manifest[0]}')"

log "Installing inline manifest into Matrix Hub: ${HUB_URL}/catalog/install"
curl -fsS -X POST "${HUB_URL%/}/catalog/install" \
  "${auth_flags[@]}" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
| jq . || true

# --- Ensure remotes: add DEFAULT_REMOTE if needed; remove noisy local remote if present ---
log "Ensuring a valid remote exists (and pruning noisy local remote if present)…"
REMOTES_JSON="$(curl -fsS "${HUB_URL%/}/remotes" | jq .)"
CURRENT_URLS=($(echo "$REMOTES_JSON" | jq -r '.items[].url'))

has_default=0
has_noisy=0
for u in "${CURRENT_URLS[@]:-}"; do
  [[ "$u" == "$DEFAULT_REMOTE" ]] && has_default=1
  [[ "$u" == "$NOISY_LOCAL_URL" ]] && has_noisy=1
done

if [[ $has_default -eq 0 ]]; then
  log "Adding default remote: $DEFAULT_REMOTE"
  curl -fsS -X POST "${HUB_URL%/}/remotes" \
    "${auth_flags[@]}" \
    -H "Content-Type: application/json" \
    -d "$(jq -nc --arg url "$DEFAULT_REMOTE" '{url:$url}')" \
  | jq . || true
fi

if [[ "$REMOVE_NOISY_LOCAL" == "1" && $has_noisy -eq 1 ]]; then
  warn "Removing noisy local remote (404s in your logs): $NOISY_LOCAL_URL"
  curl -fsS -X DELETE "${HUB_URL%/}/remotes" \
    "${auth_flags[@]}" \
    -H "Content-Type: application/json" \
    -d "$(jq -nc --arg url "$NOISY_LOCAL_URL" '{url:$url}')" \
  | jq . || true
fi

# (Re)read remotes for info
REMOTES_JSON="$(curl -fsS "${HUB_URL%/}/remotes" | jq .)"
COUNT="$(echo "$REMOTES_JSON" | jq -r '.count')"
log "Remotes configured: $COUNT"
echo "$REMOTES_JSON" | jq .

# --- Trigger ingest + gateway sync ---
log "Triggering /remotes/sync (ingest + gateway registration)"
SYNC_JSON="$(curl -fsS -X POST "${HUB_URL%/}/remotes/sync" \
  "${auth_flags[@]}" \
  -H "accept: application/json")"
echo "$SYNC_JSON" | jq .

log "✅ Done."
echo "   In MCP-Gateway UI, you should now see:"
echo "   • Federated Gateways: ${NAME}  →  ${SERVER_URL}"
echo "   • Registered Tools:   ${TOOL_NAME} (Type: MCP, URL: ${SERVER_URL})"
echo "   Use: ./scripts/verify_token.sh to list /gateways"
