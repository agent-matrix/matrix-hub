#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# scripts/register_hello_server.sh
#   - Fetch manifest from remote index
#   - Install into Matrix Hub
#   - Extract mcp_registration
#   - Register tool, resources, prompts, and federated gateway
#   - Retry on transient errors, poll until active
# -----------------------------------------------------------------------------

# —— Configuration (override via ENV) ——
HUB_URL="${HUB_URL:-http://127.0.0.1:7300}"
GATEWAY_URL="${GATEWAY_URL:-http://127.0.0.1:4444}"
REMOTE_INDEX="${REMOTE_INDEX:-https://raw.githubusercontent.com/ruslanmv/hello-mcp/refs/heads/main/matrix/index.json}"

export JWT_SECRET_KEY="${JWT_SECRET_KEY:-my-test-key}"
export BASIC_AUTH_USERNAME="${BASIC_AUTH_USERNAME:-admin}"
export BASIC_AUTH_PASSWORD="${BASIC_AUTH_PASSWORD:-changeme}"

# Helper to mint a fresh token
get_token() {
  python3 - <<PYCODE
import os
from src.utils.jwt_helper import get_mcp_admin_token
print(get_mcp_admin_token(
  secret=os.getenv("JWT_SECRET_KEY"),
  username=os.getenv("BASIC_AUTH_USERNAME"),
  ttl_seconds=600,
  fallback_token=os.getenv("ADMIN_TOKEN"),
))
PYCODE
}

# Normalize Gateway URL (strip /admin and trailing slash)
GATEWAY_URL="${GATEWAY_URL%/admin}"
GATEWAY_URL="${GATEWAY_URL%/}"
echo "🛠 Using Gateway URL: $GATEWAY_URL"

# 1) Fetch manifest URL
echo "▶️ Fetching index.json from $REMOTE_INDEX …"
MANIFEST_URL="$(curl -fsSL "$REMOTE_INDEX" | jq -r '
  if (.manifests|type=="array") then .manifests[0]
  elif (.items|type=="array")    then .items[0].manifest_url
  elif (.entries|type=="array")  then "\(.entries[0].base_url)\(.entries[0].path)"
  else empty end
')"
[[ -n "$MANIFEST_URL" ]] || { echo "✖ No manifest URL found"; exit 1; }
echo "✔ Manifest URL: $MANIFEST_URL"

# 2) Download manifest
echo "▶️ Downloading manifest…"
MANIFEST_JSON="$(curl -fsSL "$MANIFEST_URL")"
ENTITY_UID="$(jq -r '"\(.type):\(.id)@\(.version)"' <<<"$MANIFEST_JSON")"
echo "✔ Entity UID: $ENTITY_UID"

# 3) Install into Matrix Hub
echo -e "\n▶️ Installing into Matrix Hub…"
INSTALL_RES="$(curl -fsSL -X POST "$HUB_URL/catalog/install" \
  -H "Content-Type: application/json" \
  -d "{\"id\":\"$ENTITY_UID\",\"target\":\"./\",\"manifest\":$MANIFEST_JSON}")"
echo "$INSTALL_RES" | jq .

# 4) Extract mcp_registration
echo -e "\n▶️ Extracting mcp_registration…"
MCP_REG="$(jq -c '(.lockfile.entities[0].mcp_registration // .mcp_registration) // empty' <<<"$INSTALL_RES")"
if [[ -z "$MCP_REG" ]]; then
  echo "ℹ️ No mcp_registration in Hub response; falling back to manifest."
  MCP_REG="$(jq -c '.mcp_registration // empty' <<<"$MANIFEST_JSON")"
fi
[[ -n "$MCP_REG" ]] || { echo "✖ No mcp_registration found; nothing to do."; exit 1; }
echo "$MCP_REG" | jq .

# 5) Register on MCP-Gateway
echo -e "\n▶️ Registering on MCP-Gateway at $GATEWAY_URL …"
TOKEN="$(get_token)"

# — Tool
echo " • Tool…"
TOOL_SPEC="$(jq -c '.tool | .name = .id' <<<"$MCP_REG")"
echo "   → Payload: $TOOL_SPEC"
TOOL_OUT="$(curl -s -w "\n%{http_code}" -X POST "$GATEWAY_URL/tools" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "$TOOL_SPEC")"
TOOL_BODY="$(sed '$d' <<<"$TOOL_OUT")"
TOOL_CODE="$(tail -n1 <<<"$TOOL_OUT")"
if [[ "$TOOL_CODE" == "409" ]]; then
  echo "   ⚠️ Tool already exists"
elif [[ "$TOOL_CODE" =~ ^2 ]]; then
  echo "   ✅ Tool registered"
else
  echo "   ❌ Tool failed ($TOOL_CODE)"; exit 1
fi

# — Resources
echo " • Resources…"
mapfile -t RESOURCE_SPECS < <(jq -c '.resources[]' <<<"$MCP_REG")
RESOURCE_IDS=()
for R in "${RESOURCE_SPECS[@]}"; do
  uri=$(jq -r '.uri' <<<"$R")
  RESP="$(curl -s -w "\n%{http_code}" -X POST "$GATEWAY_URL/resources" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$R")"
  CODE="$(tail -n1 <<<"$RESP")"
  if [[ $CODE =~ ^2 ]] || [[ $CODE == "409" ]]; then
    ID="$(curl -sSL -H "Authorization: Bearer $TOKEN" "$GATEWAY_URL/resources" \
      | jq -r --arg uri "$uri" '.[] | select(.uri==$uri) | .id')"
    echo "   ✅ Resource ID $ID"
    RESOURCE_IDS+=("$ID")
  else
    echo "   ❌ Resource failed ($CODE)"; exit 1
  fi
done

# — Prompts
echo " • Prompts…"
mapfile -t PROMPT_SPECS < <(jq -c '.prompts // [] | .[]' <<<"$MCP_REG")
PROMPT_IDS=()
if (( ${#PROMPT_SPECS[@]} )); then
  for P in "${PROMPT_SPECS[@]}"; do
    pid=$(jq -r '.id' <<<"$P")
    RESP="$(curl -s -w "\n%{http_code}" -X POST "$GATEWAY_URL/prompts" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "$P")"
    CODE="$(tail -n1 <<<"$RESP")"
    if [[ $CODE =~ ^2 ]] || [[ $CODE == "409" ]]; then
      ID="$(curl -sSL -H "Authorization: Bearer $TOKEN" "$GATEWAY_URL/prompts" \
        | jq -r --arg pid "$pid" '.[] | select(.id==$pid) | .id')"
      echo "   ✅ Prompt ID $ID"
      PROMPT_IDS+=("$ID")
    else
      echo "   ❌ Prompt failed ($CODE)"; exit 1
    fi
  done
  PROMPTS_JSON=$(printf '%s\n' "${PROMPT_IDS[@]}" | jq -R . | jq -s 'map(tonumber)')
else
  echo "   ℹ️ No prompts to register, skipping."
  PROMPTS_JSON='[]'
fi

# — Federated Gateway registration
echo " • Gateway…"
# derive the correct SSE endpoint
SERVER_BASE="$(jq -r '.server.url' <<<"$MCP_REG")"
SERVER_BASE="${SERVER_BASE%/}"

# if transport is SSE, use /messages/ (as defined in server.py)
TRANSPORT="$(jq -r '.server.transport' <<<"$MCP_REG")"
if [[ "$TRANSPORT" == "SSE" ]]; then
  SERVER_URL="${SERVER_BASE}/messages/"
else
  SERVER_URL="$SERVER_BASE"
fi

echo "   → Using SSE endpoint: $SERVER_URL"

# build JSON arrays with numeric IDs
TOOLS_JSON=$(jq -n --arg t "$(jq -r '.tool.id' <<<"$MCP_REG")" '[ $t ]')
RES_JSON=$(printf '%s\n' "${RESOURCE_IDS[@]}" | jq -R . | jq -s 'map(tonumber)')

FINAL_PAYLOAD="$(
  jq -n \
    --arg name        "$(jq -r '.server.name' <<<"$MCP_REG")" \
    --arg desc        "$(jq -r '.server.description' <<<"$MCP_REG")" \
    --arg url         "$SERVER_URL" \
    --argjson tools     "$TOOLS_JSON" \
    --argjson resources "$RES_JSON" \
    --argjson prompts   "$PROMPTS_JSON" \
    '{
      name:                $name,
      description:         $desc,
      url:                 $url,
      associated_tools:      $tools,
      associated_resources:  $resources,
      associated_prompts:    $prompts
    }'
)"
echo "   → Final payload: $(jq . <<<"$FINAL_PAYLOAD")"

# retry on transient 5xx up to 3 times
for attempt in 1 2 3; do
  OUT="$(curl -s -w "\n%{http_code}" -X POST "$GATEWAY_URL/gateways" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$FINAL_PAYLOAD")"
  CODE="$(tail -n1 <<<"$OUT")"
  if [[ "$CODE" =~ ^2 ]]; then
    echo "   ✅ Gateway registered"; break
  elif [[ "$CODE" == "409" ]]; then
    echo "   ⚠️ Gateway already exists"; break
  elif [[ "$CODE" =~ ^5 ]]; then
    echo "   ⚠️ Transient error ($CODE), retrying…"; sleep 1
  else
    echo "   ❌ Gateway failed ($CODE)"; exit 1
  fi
done

# 6) Poll until gateway appears
GWN="$(jq -r '.server.name' <<<"$MCP_REG")"
echo -e "\n▶️ Waiting for gateway \"$GWN\" to appear…"
for i in {1..6}; do
  FOUND="$(curl -sSL -H "Authorization: Bearer $TOKEN" "$GATEWAY_URL/gateways" \
    | jq -r --arg name "$GWN" '.[] | select(.name==$name)')"
  if [[ -n "$FOUND" ]]; then
    echo "✅ Gateway is in catalog:"; jq . <<<"$FOUND"; exit 0
  fi
  echo "  …attempt $i/6, sleeping 2s"; sleep 2
done

echo "❌ Gateway did not appear after ~12s"; exit 1
