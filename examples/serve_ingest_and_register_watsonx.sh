#!/usr/bin/env bash
set -Eeuo pipefail

# Serve repo → read examples/index.json → fetch & patch manifest(s) → install into Matrix Hub
# ALSO: Register Tool/Resources/Prompts/Gateway into MCP-Gateway.
#
# Ports in play:
#   Hub API        : 127.0.0.1:443      (HUB_URL)
#   Watsonx agent  : 127.0.0.1:6288/sse (your server.py)
#   Static server  : 127.0.0.1:8000+    (this script, ephemeral)
#
# Required: jq, curl, python
# Env (from .env or shell):
#   HUB_URL (default http://127.0.0.1:443)
#   HUB_TOKEN (optional)
#   MCP_GATEWAY_URL (default http://127.0.0.1:4444)
#   MCP_GATEWAY_TOKEN (REQUIRED for gateway registration) – include "Bearer " or raw token

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="${REPO_ROOT:-"$(cd "$SCRIPT_DIR/.." && pwd)"}"

# --- .env (optional) ---
if [[ -z "${ENV_FILE:-}" ]]; then
  [[ -f "$REPO_ROOT/.env" ]] && ENV_FILE="$REPO_ROOT/.env" || true
fi
if [[ -n "${ENV_FILE:-}" && -f "$ENV_FILE" ]]; then
  echo "ℹ️  Loading .env from $ENV_FILE"
  set +u; set -a; source "$ENV_FILE"; set +a; set -u
fi

# --- Config (Hub) ---
HUB_URL="${HUB_URL:-${MATRIX_HUB_URL:-http://127.0.0.1:443}}"; HUB_URL="${HUB_URL%/}"
HUB_TOKEN="${HUB_TOKEN:-${MATRIX_HUB_TOKEN:-}}"

# --- Config (Gateway) ---
GATEWAY_URL="${GATEWAY_URL:-${MCP_GATEWAY_URL:-http://127.0.0.1:4444}}"; GATEWAY_URL="${GATEWAY_URL%/}"
GATEWAY_TOKEN="${GATEWAY_TOKEN:-${MCP_GATEWAY_TOKEN:-}}"
[[ -z "$GATEWAY_TOKEN" ]] && { echo "✖ MCP-Gateway token missing. Set MCP_GATEWAY_TOKEN (or GATEWAY_TOKEN) in .env"; exit 1; }

# --- Static server (for index/manifest) ---
SERVE_DIR="${SERVE_DIR:-$REPO_ROOT}"
SERVE_HOST="${SERVE_HOST:-127.0.0.1}"
SERVE_PORT="${SERVE_PORT:-8000}"

INDEX_PATH_REL="${INDEX_PATH_REL:-examples/index.json}"
[[ ! -f "$SERVE_DIR/${INDEX_PATH_REL#/}" && -f "$SERVE_DIR/examples/local_index.json" ]] && INDEX_PATH_REL="examples/local_index.json"
INDEX_PATH_REL="${INDEX_PATH_REL#/}"
INDEX_URL="http://${SERVE_HOST}:${SERVE_PORT}/${INDEX_PATH_REL}"
TARGET_DIR="${TARGET_DIR:-./}"

need(){ command -v "$1" >/dev/null 2>&1 || { echo "✖ $1 is required"; exit 1; }; }
need jq; need curl; need python

norm_auth(){ local t="${1:-}"; [[ -z "$t" ]] && { echo ""; return; }; [[ "$t" =~ ^([Bb]earer|[Bb]asic)\  ]] && echo "$t" || echo "Bearer $t"; }

# Quick port check (no lsof/ss needed)
port_in_use(){ python - "$SERVE_HOST" "$1" <<'PY'
import socket, sys
h, p = sys.argv[1], int(sys.argv[2])
s= socket.socket(); s.settimeout(0.3)
try:
  s.connect((h,p)); print('1')
except Exception:
  print('0')
finally:
  s.close()
PY
}

# Pick a free port quickly (8000..8020)
if [[ "$(port_in_use "$SERVE_PORT")" == "1" ]]; then
  for p in $(seq 8000 8020); do
    if [[ "$(port_in_use "$p")" == "0" ]]; then SERVE_PORT="$p"; break; fi
  done
  INDEX_URL="http://${SERVE_HOST}:${SERVE_PORT}/${INDEX_PATH_REL}"
fi

# Hub TLS autodetect on :443
HUB_CURL_OPTS=()
if [[ "$HUB_URL" =~ ^https?://127\.0\.0\.1:443$ ]]; then
  if curl -k -sS -I --max-time 2 "https://127.0.0.1:443/health" >/dev/null 2>&1; then
    HUB_URL="https://127.0.0.1:443"; HUB_CURL_OPTS=(-k)
  else
    HUB_URL="http://127.0.0.1:443"
  fi
fi
[[ "$HUB_URL" == https:* ]] && HUB_CURL_OPTS=(-k)
[[ -n "${HUB_TOKEN:-}" ]] && HUB_AUTH=(-H "Authorization: $(norm_auth "$HUB_TOKEN")") || HUB_AUTH=()

# Gateway TLS
GATEWAY_CURL_OPTS=()
[[ "$GATEWAY_URL" == https:* ]] && GATEWAY_CURL_OPTS=(-k)
GW_AUTH=(-H "Authorization: $(norm_auth "$GATEWAY_TOKEN")")

# Index must exist on disk
[[ -f "$SERVE_DIR/${INDEX_PATH_REL#/}" ]] || { echo "✖ Missing index: $SERVE_DIR/${INDEX_PATH_REL#/}"; exit 1; }

# Start static server
pushd "$SERVE_DIR" >/dev/null
python -m http.server "$SERVE_PORT" --bind "$SERVE_HOST" >/dev/null 2>&1 &
SERVER_PID=$!
popd >/dev/null
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT

echo "▶️  Serving $SERVE_DIR at http://$SERVE_HOST:$SERVE_PORT/"
echo "ℹ️  Hub:     $HUB_URL"
echo "ℹ️  Gateway: $GATEWAY_URL"

# Wait index
for i in {1..60}; do
  code="$(curl -sS -w '%{http_code}' -o /dev/null "$INDEX_URL" || true)"
  [[ "$code" =~ ^2..$ ]] && { echo "✔ Index ready ($INDEX_URL)"; break; }
  (( i==60 )) && { echo "✖ Index not reachable ($INDEX_URL)"; exit 1; }
  sleep 0.25
done

INDEX_JSON="$(curl -fsSL "$INDEX_URL")"

# Extract manifest refs (relative OK)
mapfile -t MANIFESTS < <(jq -r '
  if (.manifests|type=="array") then .manifests[]
  elif (.items|type=="array") then .items[].manifest_url
  elif (.entries|type=="array") then (.entries[] | ( (.base_url//"") + (.path//"") ))
  else empty end' <<<"$INDEX_JSON")
[[ ${#MANIFESTS[@]} -gt 0 ]] || { echo "✖ No manifest refs in index"; exit 1; }

# Helpers
resolve(){ python - "$INDEX_URL" "$1" <<'PY'
import sys
from urllib.parse import urlparse, urljoin
base, ref = sys.argv[1].strip(), sys.argv[2].strip()
if not ref or ref == 'null':
  print(''); raise SystemExit
if ref.startswith(('http://','https://')):
  print(ref); raise SystemExit
p = urlparse(base); root = f"{p.scheme}://{p.netloc}/"
print(urljoin(root, ref.lstrip('/')))
PY
}
rewrite_local(){ python - "$1" "$2" "$3" <<'PY'
import sys
from urllib.parse import urlparse, urlunparse
u, host, port = sys.argv[1], sys.argv[2], sys.argv[3]
p = urlparse(u)
if p.hostname in {host,'127.0.0.1','localhost','0.0.0.0'} and (p.port and str(p.port)!=port):
  p = p._replace(scheme='http', netloc=f"{host}:{port}")
print(urlunparse(p))
PY
}

# Gateway helpers
lookup_resource_id() {
  local name="$1" uri="$2"
  local body code
  body="$(curl -sS "${GATEWAY_CURL_OPTS[@]}" "${GW_AUTH[@]}" -H "Accept: application/json" "$GATEWAY_URL/resources")" || { echo ""; return 0; }
  jq -r --arg n "$name" --arg u "$uri" '
    .[] | select((.name==$n) or (.uri==$u) or ((.id|tostring)==$n)) | .id
  ' <<<"$body" | head -n1
}
lookup_prompt_id() {
  local pid="$1" name="$2"
  local body
  body="$(curl -sS "${GATEWAY_CURL_OPTS[@]}" "${GW_AUTH[@]}" -H "Accept: application/json" "$GATEWAY_URL/prompts")" || { echo ""; return 0; }
  jq -r --arg i "$pid" --arg n "$name" '
    .[] | select((.name==$n) or ((.id|tostring)==$i)) | .id
  ' <<<"$body" | head -n1
}

post_json() {
  local url="$1"; shift
  local data="$1"; shift
  local -a extra=( "$@" )
  local tmp; tmp="$(mktemp)"
  local code
  code="$(curl -sS -w '%{http_code}' -o "$tmp" "$url" -X POST -H "Content-Type: application/json" "${extra[@]}" -d "$data" || true)"
  echo "$code"
  cat "$tmp"
  rm -f "$tmp"
}

# Process each manifest
for RAW in "${MANIFESTS[@]}"; do
  MURL="$(resolve "$RAW")"; [[ -z "$MURL" ]] && { echo "• skip blank ref"; continue; }
  MURL="$(rewrite_local "$MURL" "$SERVE_HOST" "$SERVE_PORT")"

  echo "▶️  Fetch $MURL"
  MANIFEST="$(curl -fsSL "$MURL" || true)"; [[ -z "$MANIFEST" ]] && { echo "   ✖ fetch failed"; continue; }

  BASE="$(jq -r '.mcp_registration.server.url // empty' <<<"$MANIFEST")"; [[ -z "$BASE" ]] && { echo "   ⚠ no server.url"; continue; }
  BASE="${BASE%/}"; SSE="${BASE}/sse"

  # Preflight SSE
  echo "   ⏱ Preflight SSE: $SSE"
  set +e +o pipefail
  st="$(curl -sS -I --connect-timeout 1 --max-time 2 "$SSE" 2>/dev/null | head -n1 | awk '{print $2}')"
  [[ -z "${st:-}" ]] && st="$(curl -sS -N --connect-timeout 1 --max-time 2 -D- -o /dev/null "$SSE" 2>/dev/null | head -n1 | awk '{print $2}')"
  set -e -o pipefail
  [[ "${st:-}" =~ ^2[0-9][0-9]$ ]] && echo "   ✓ SSE reachable (HTTP $st)" || echo "   ⚠ SSE preflight non-2xx (${st:-timeout}). Continuing…"

  PATCHED="$(jq --arg url "$SSE" '.mcp_registration.server.url=$url | del(.mcp_registration.server.transport)' <<<"$MANIFEST")"

  # 1) Install into Matrix Hub
  ENTITY_UID="$(jq -r '"\(.type):\(.id)@\(.version)"' <<<"$MANIFEST")"
  echo "   📦 Hub install $ENTITY_UID → $HUB_URL/catalog/install"
  code="$(curl -sS -w '%{http_code}' -o /dev/null "$HUB_URL/catalog/install" \
     "${HUB_CURL_OPTS[@]}" "${HUB_AUTH[@]}" -H 'Content-Type: application/json' \
     -d "$(jq -nc --arg id "$ENTITY_UID" --arg target "$TARGET_DIR" --argjson manifest "$PATCHED" '{id:$id,target:$target,manifest:$manifest}')" || true)"
  [[ "$code" =~ ^2..$ ]] && echo "   ✅ Hub ok (HTTP $code)" || echo "   ✖ Hub failed (HTTP $code)"

  # 2) Register in MCP-Gateway (tool/resources/prompts/gateway)
  TOOL_ID="$(jq -r '.mcp_registration.tool.id // empty' <<<"$PATCHED")"
  TOOL_NAME="$(jq -r '.mcp_registration.tool.name // empty' <<<"$PATCHED")"
  TOOL_DESC="$(jq -r '.mcp_registration.tool.description // ""' <<<"$PATCHED")"
  [[ -z "$TOOL_NAME" && -n "$TOOL_ID" ]] && TOOL_NAME="$TOOL_ID"

  GW_NAME="$(jq -r '.mcp_registration.server.name // "watsonx-mcp"' <<<"$PATCHED")"
  GW_DESC="$(jq -r '.mcp_registration.server.description // ""' <<<"$PATCHED")"

  # Tool upsert
  if [[ -n "${TOOL_ID:-}" || -n "${TOOL_NAME:-}" ]]; then
    TOOL_PAY="$(jq -nc --arg id "${TOOL_ID:-}" --arg name "${TOOL_NAME:-watsonx}" --arg desc "$TOOL_DESC" \
      '{name:$name, description:$desc, integration_type:"MCP", request_type:"SSE"} + (if ($id|length)>0 then {id:$id} else {} end)')"
    resp_code_and_body="$(post_json "$GATEWAY_URL/tools" "$TOOL_PAY" "${GATEWAY_CURL_OPTS[@]}" "${GW_AUTH[@]}")"
    code="${resp_code_and_body%%$'\n'*}"
    [[ "$code" =~ ^(200|201|409)$ ]] && echo "   ✓ Gateway tool upsert (${TOOL_ID:-$TOOL_NAME}) [HTTP $code]" || echo "   ✖ Gateway tool failed ($code)"
  fi

  # Resources
  declare -a RES_IDS=()
  RES_LEN="$(jq -r '(.mcp_registration.resources // []) | length' <<<"$PATCHED")"
  if [[ "$RES_LEN" != "0" ]]; then
    for i in $(seq 0 $((RES_LEN-1))); do
      R_ID="$(jq -r ".mcp_registration.resources[$i].id // empty" <<<"$PATCHED")"
      R_NAME="$(jq -r ".mcp_registration.resources[$i].name // empty" <<<"$PATCHED")"
      R_TYPE="$(jq -r ".mcp_registration.resources[$i].type // empty" <<<"$PATCHED")"
      R_URI="$(jq -r  ".mcp_registration.resources[$i].uri  // empty" <<<"$PATCHED")"
      R_CONTENT="$(jq -r ".mcp_registration.resources[$i].content // empty" <<<"$PATCHED")"
      RES_PAY="$(jq -nc --arg id "$R_ID" --arg name "$R_NAME" --arg type "$R_TYPE" --arg uri "$R_URI" --arg content "$R_CONTENT" '
        {name:$name, type:$type}
        + (if ($id|length)>0 then {id:$id} else {} end)
        + (if ($uri|length)>0 then {uri:$uri} else {} end)
        + (if ($type=="inline" and ($content|length)>0) then {content:$content} else {} end)
      ')"
      resp_code_and_body="$(post_json "$GATEWAY_URL/resources" "$RES_PAY" "${GATEWAY_CURL_OPTS[@]}" "${GW_AUTH[@]}")"
      code="${resp_code_and_body%%$'\n'*}"
      body="${resp_code_and_body#*$'\n'}"
      if [[ "$code" =~ ^(200|201)$ ]]; then
        rid="$(jq -r '.id // empty' <<<"$body")"
      elif [[ "$code" == "409" ]]; then
        rid="$(lookup_resource_id "$R_NAME" "$R_URI")"
      else
        echo "   ✖ Resource failed ($code): $body"; continue
      fi
      [[ -z "${rid:-}" || "${rid:-null}" == "null" ]] && rid="$(lookup_resource_id "$R_NAME" "$R_URI")"
      if [[ -z "$rid" ]]; then
        echo "   ✖ Could not resolve numeric resource id for '$R_NAME'"; continue
      fi
      RES_IDS+=("$rid")
      echo "   ✓ Resource upserted ($R_NAME → id=$rid) [HTTP $code]"
    done
  fi

  # Prompts (optional)
  declare -a PR_IDS=()
  PR_LEN="$(jq -r '(.mcp_registration.prompts // []) | length' <<<"$PATCHED")"
  if [[ "$PR_LEN" != "0" ]]; then
    for i in $(seq 0 $((PR_LEN-1))); do
      P_ID="$(jq -r ".mcp_registration.prompts[$i].id // empty" <<<"$PATCHED")"
      P_NAME="$(jq -r ".mcp_registration.prompts[$i].name // empty" <<<"$PATCHED")"
      P_DESC="$(jq -r ".mcp_registration.prompts[$i].description // \"\"" <<<"$PATCHED")"
      P_TPL="$(jq -r  ".mcp_registration.prompts[$i].template // empty" <<<"$PATCHED")"
      PR_PAY="$(jq -nc --arg id "$P_ID" --arg name "$P_NAME" --arg desc "$P_DESC" --arg tpl "$P_TPL" \
        '{name:$name, description:$desc, template:$tpl} + (if ($id|length)>0 then {id:$id} else {} end)')"
      resp_code_and_body="$(post_json "$GATEWAY_URL/prompts" "$PR_PAY" "${GATEWAY_CURL_OPTS[@]}" "${GW_AUTH[@]}")"
      code="${resp_code_and_body%%$'\n'*}"
      body="${resp_code_and_body#*$'\n'}"
      if [[ "$code" =~ ^(200|201)$ ]]; then
        pid="$(jq -r '.id // empty' <<<"$body")"
      elif [[ "$code" == "409" ]]; then
        pid="$(lookup_prompt_id "$P_ID" "$P_NAME")"
      else
        echo "   ✖ Prompt failed ($code): $body"; continue
      fi
      [[ -z "$pid" ]] && { echo "   ✖ Could not resolve numeric prompt id for '$P_NAME'"; continue; }
      PR_IDS+=("$pid")
      echo "   ✓ Prompt upserted ($P_NAME → id=$pid) [HTTP $code]"
    done
  fi

  # Federated Gateway registration
  # Arrays → JSON
  if [[ -n "${TOOL_ID:-}" ]]; then TOOLS_JSON="$(jq -n --arg t "$TOOL_ID" '[ $t ]')"; else TOOLS_JSON="[]"; fi
  if [[ ${#RES_IDS[@]} -gt 0 ]]; then RIDS_JSON="$(printf '%s\n' "${RES_IDS[@]}" | jq -R . | jq -s 'map(tonumber)')"; else RIDS_JSON="[]"; fi
  if [[ ${#PR_IDS[@]}  -gt 0 ]]; then PIDS_JSON="$(printf '%s\n' "${PR_IDS[@]}"  | jq -R . | jq -s 'map(tonumber)')"; else PIDS_JSON="[]"; fi

  GW_PAY="$(jq -n \
     --arg name "$GW_NAME" --arg desc "$GW_DESC" --arg url "$SSE" \
     --argjson tools "$TOOLS_JSON" --argjson resources "$RIDS_JSON" --argjson prompts "$PIDS_JSON" \
     '{name:$name, description:$desc, url:$url, associated_tools:$tools, associated_resources:$resources, associated_prompts:$prompts}')"

  resp_code_and_body="$(post_json "$GATEWAY_URL/gateways" "$GW_PAY" "${GATEWAY_CURL_OPTS[@]}" "${GW_AUTH[@]}")"
  code="${resp_code_and_body%%$'\n'*}"
  if [[ "$code" =~ ^(200|201|409)$ ]]; then
    echo "   ✅ Gateway upserted ($GW_NAME) [HTTP $code]"
  else
    echo "   ✖ Gateway register failed ($code):"
    echo "$resp_code_and_body" | sed -e 's/^/     /'
  fi

done

echo "✅ Done (Hub installed + Gateway registered)."
