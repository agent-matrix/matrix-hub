#!/usr/bin/env bash
set -Eeuo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Local install + MCP-Gateway registration + (optional) Matrix Hub install
#   • loads .env from repo root (or any ancestor of $PWD / script dir)
#   • patches the manifest to point to /sse (and removes transport)
#   • registers Tool/Resources/Prompts/Gateway in MCP-Gateway
#   • optionally POSTs the same manifest to Matrix Hub /catalog/install
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

find_env_up() {
  local dir="$1"
  while [[ -n "$dir" && "$dir" != "/" && "$dir" != "." ]]; do
    if [[ -f "$dir/.env" ]]; then
      echo "$dir/.env"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

ENV_FILE="${ENV_FILE:-}"
if [[ -z "${ENV_FILE:-}" ]]; then
  env_from_pwd="$(find_env_up "$PWD" || true)"
  env_from_script="$(find_env_up "$SCRIPT_DIR" || true)"
  if [[ -n "${env_from_pwd:-}" ]]; then
    ENV_FILE="$env_from_pwd"
  elif [[ -n "${env_from_script:-}" ]]; then
    ENV_FILE="$env_from_script"
  fi
fi

if [[ -f "${ENV_FILE:-}" ]]; then
  echo "ℹ️  Loading .env from $ENV_FILE"
  set +u; set -a; source "$ENV_FILE"; set +a; set -u
else
  echo "⚠️  No .env found via upward search from: $PWD and $SCRIPT_DIR"
fi

# ---------- Config ----------
MANIFEST_PATH="${MANIFEST_PATH:-examples/manifests/watsonx.manifest.json}"
ENTITY_UID="${ENTITY_UID:-mcp_server:watsonx-agent@0.1.0}"

# MCP-Gateway (required)
GATEWAY_URL="${GATEWAY_URL:-${MCP_GATEWAY_URL:-http://127.0.0.1:4444}}"
GATEWAY_URL="${GATEWAY_URL%/admin}"
GATEWAY_URL="${GATEWAY_URL%/}"
GATEWAY_TOKEN="${GATEWAY_TOKEN:-${MCP_GATEWAY_TOKEN:-}}"

# Matrix Hub (optional block)
HUB_URL="${HUB_URL:-${MATRIX_HUB_URL:-}}"
HUB_TOKEN="${HUB_TOKEN:-${MATRIX_HUB_TOKEN:-}}"
TARGET_DIR="${TARGET_DIR:-./}"    # only used for Hub /catalog/install

TMP_MANIFEST="$(mktemp -t watsonx_manifest.XXXXXX.json)"
trap 'rm -f "$TMP_MANIFEST" 2>/dev/null || true' EXIT

# ---------- Checks ----------
command -v jq >/dev/null 2>&1 || { echo "✖ jq is required"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "✖ curl is required"; exit 1; }
[[ -f "$MANIFEST_PATH" ]] || { echo "✖ Manifest not found: $MANIFEST_PATH"; exit 1; }

if [[ -z "${GATEWAY_TOKEN}" ]]; then
  echo "✖ ERROR: MCP Gateway token missing." >&2
  echo "  Set MCP_GATEWAY_TOKEN (or GATEWAY_TOKEN) in your .env." >&2
  exit 1
fi

# ---------- Helpers ----------
norm_auth() {
  local t="${1:-}"
  if [[ -z "$t" ]]; then echo ""; return; fi
  local low; low="$(echo "$t" | tr '[:upper:]' '[:lower:]')"
  if [[ "$low" == bearer\ * || "$low" == basic\ * ]]; then
    echo "$t"
  else
    echo "Bearer $t"
  fi
}

post_json() {
  local url="$1"; shift
  local data="$1"; shift
  local -a args=( "$@" -H "Content-Type: application/json" )
  local tmp_body; tmp_body="$(mktemp)"
  CODE="$(curl -sS -w '%{http_code}' -o "$tmp_body" "${args[@]}" -X POST "$url" -d "$data")" || true
  BODY="$(cat "$tmp_body")"; rm -f "$tmp_body"
}

get_json() {
  local url="$1"; shift
  local -a args=( "$@" -H "Accept: application/json" )
  BODY="$(curl -sS "${args[@]}" "$url")" || BODY=""
  CODE=200
}

# parse_list: normalizes GET responses to a flat array
# supports: []  or  {"items":[...]}  or  {"data":[...]}
parse_list() {
  jq -c '
    if type=="array" then .
    else
      ( .items? // .data? // [] )
    end
  '
}

# lookup: robustly extract numeric id by name/uri/id (string/number), case-insensitive name
lookup_resource_id() {
  local name="$1" uri="$2"
  get_json "$GATEWAY_URL/resources" "${GATEWAY_CURL_OPTS[@]}" -H "Authorization: $(norm_auth "$GATEWAY_TOKEN")"
  echo "$BODY" | parse_list | jq -r --arg n "$name" --arg u "$uri" '
    map(select(
      (.name|tostring|ascii_downcase)==($n|ascii_downcase)
      or (.uri|tostring)==$u
      or ((.id|tostring)==$n)
    ))
    | (.[0].id // empty)
  ' | head -n1
}

lookup_prompt_id() {
  local pid="$1" name="$2"
  get_json "$GATEWAY_URL/prompts" "${GATEWAY_CURL_OPTS[@]}" -H "Authorization: $(norm_auth "$GATEWAY_TOKEN")"
  echo "$BODY" | parse_list | jq -r --arg i "$pid" --arg n "$name" '
    map(select(
      ((.id|tostring)==$i) or ((.name|tostring|ascii_downcase)==($n|ascii_downcase))
    ))
    | (.[0].id // empty)
  ' | head -n1
}

# ---------- Build SSE URL & patch manifest ----------
BASE_URL="$(jq -r '.mcp_registration.server.url // empty' "$MANIFEST_PATH")"
[[ -z "$BASE_URL" ]] && { echo "✖ No .mcp_registration.server.url in manifest"; exit 1; }
BASE_URL="${BASE_URL%/}"
SSE_URL="${BASE_URL}/sse"

echo "▶️  Preflight SSE: $SSE_URL"
set +e +o pipefail
status="$(curl -sS -I --connect-timeout 1 --max-time 2 "$SSE_URL" 2>/dev/null | head -n1 | awk '{print $2}')"
if [[ -z "${status:-}" ]]; then
  status="$(curl -sS -N --connect-timeout 1 --max-time 2 -D- -o /dev/null "$SSE_URL" 2>/dev/null | head -n1 | awk '{print $2}')"
fi
set -e -o pipefail
[[ "${status:-}" =~ ^2[0-9][0-9]$ ]] && echo "   ✓ SSE reachable (HTTP $status)" || echo "   ⚠ SSE preflight non-2xx (${status:-timeout}). Continuing…"

jq --arg url "$SSE_URL" '
  . as $root
  | ($root
     | .mcp_registration.server.url = $url
     | if .mcp_registration.server.transport then del(.mcp_registration.server.transport) else . end
    )
' "$MANIFEST_PATH" > "$TMP_MANIFEST"

# ---------- (Optional) Install into Matrix Hub ----------
if [[ -n "${HUB_URL}" ]]; then
  # auto-detect scheme if pointing at :443 with no scheme
  HUB_URL="${HUB_URL%/}"
  if [[ "$HUB_URL" == http://127.0.0.1:443 || "$HUB_URL" == https://127.0.0.1:443 || "$HUB_URL" == 127.0.0.1:443 ]]; then
    if curl -k -sS -I --max-time 2 "https://127.0.0.1:443/health" >/dev/null 2>&1; then
      HUB_URL="https://127.0.0.1:443"
      HUB_CURL_OPTS=(-k)
    elif curl -sS -I --max-time 2 "http://127.0.0.1:443/health" >/dev/null 2>&1; then
      HUB_URL="http://127.0.0.1:443"
      HUB_CURL_OPTS=()
    else
      HUB_CURL_OPTS=()
    fi
  else
    [[ "$HUB_URL" == https:* ]] && HUB_CURL_OPTS=(-k) || HUB_CURL_OPTS=()
  fi

  echo "▶️  Installing into Matrix Hub at $HUB_URL/catalog/install"
  HUB_AUTH_HDR=()
  if [[ -n "${HUB_TOKEN:-}" ]]; then
    # try both common styles (Hub may accept either)
    HUB_AUTH_HDR=(-H "Authorization: $(norm_auth "$HUB_TOKEN")")
  fi

  post_json "$HUB_URL/catalog/install" \
    "$(jq -nc \
      --arg id "$ENTITY_UID" \
      --arg target "$TARGET_DIR" \
      --argjson manifest "$(cat "$TMP_MANIFEST")" \
      '{id:$id, target:$target, manifest:$manifest}')" \
    "${HUB_CURL_OPTS[@]}" "${HUB_AUTH_HDR[@]}"

  if [[ "$CODE" =~ ^(200|201)$ ]]; then
    echo "   ✓ Matrix Hub install ok"
  else
    echo "   ⚠ Matrix Hub install returned HTTP $CODE — continuing anyway"
    echo "     Body: $BODY"
  fi
fi

# ---------- Register directly in MCP-Gateway ----------
echo "▶️  Registering components with MCP-Gateway at $GATEWAY_URL"
[[ "$GATEWAY_URL" == https:* ]] && GATEWAY_CURL_OPTS=(-k) || GATEWAY_CURL_OPTS=()
AUTH_GW="$(norm_auth "$GATEWAY_TOKEN")"

TOOL_ID="$(jq -r '.mcp_registration.tool.id // empty' "$TMP_MANIFEST")"
TOOL_NAME="$(jq -r '.mcp_registration.tool.name // empty' "$TMP_MANIFEST")"
TOOL_DESC="$(jq -r '.mcp_registration.tool.description // ""' "$TMP_MANIFEST")"
[[ -z "$TOOL_NAME" && -n "$TOOL_ID" ]] && TOOL_NAME="$TOOL_ID"

GW_NAME="$(jq -r '.mcp_registration.server.name // "watsonx-mcp"' "$TMP_MANIFEST")"
GW_DESC="$(jq -r '.mcp_registration.server.description // ""' "$TMP_MANIFEST")"

# 1) TOOL (idempotent)
if [[ -n "${TOOL_ID:-}" || -n "${TOOL_NAME:-}" ]]; then
  TOOL_PAY="$(jq -nc \
    --arg id   "${TOOL_ID:-}" \
    --arg name "${TOOL_NAME:-watsonx-chat}" \
    --arg desc "${TOOL_DESC:-}" \
    '{name:$name, description:$desc, integration_type:"MCP", request_type:"SSE"}
     + (if ($id|length)>0 then {id:$id} else {} end)'
  )"
  post_json "$GATEWAY_URL/tools" "$TOOL_PAY" "${GATEWAY_CURL_OPTS[@]}" -H "Authorization: $AUTH_GW" || true
  if [[ "$CODE" =~ ^(200|201|409)$ ]]; then
    echo "✓ Tool upserted (${TOOL_ID:-$TOOL_NAME}) [HTTP $CODE]"
  else
    echo "✖ Tool failed ($CODE): $BODY" >&2; exit 1
  fi
fi

# 2) RESOURCES → need NUMERIC IDs
declare -a RESOURCE_IDS=()
RES_COUNT="$(jq -r '(.mcp_registration.resources // []) | length' "$TMP_MANIFEST")"
if [[ "$RES_COUNT" != "0" ]]; then
  for i in $(seq 0 $((RES_COUNT-1))); do
    R_ID="$(jq -r ".mcp_registration.resources[$i].id // empty" "$TMP_MANIFEST")"
    R_NAME="$(jq -r ".mcp_registration.resources[$i].name // empty" "$TMP_MANIFEST")"
    R_TYPE="$(jq -r ".mcp_registration.resources[$i].type // empty" "$TMP_MANIFEST")"
    R_URI="$(jq -r  ".mcp_registration.resources[$i].uri  // empty" "$TMP_MANIFEST")"
    R_CONTENT="$(jq -r ".mcp_registration.resources[$i].content // empty" "$TMP_MANIFEST")"

    RES_PAY="$(jq -nc \
      --arg id "$R_ID" --arg name "$R_NAME" --arg type "$R_TYPE" --arg uri "$R_URI" --arg content "$R_CONTENT" '
      {name:$name, type:$type}
      + (if ($id|length)>0 then {id:$id} else {} end)
      + (if ($uri|length)>0 then {uri:$uri} else {} end)
      + (if ($type=="inline" and ($content|length)>0) then {content:$content} else {} end)
    ')"

    post_json "$GATEWAY_URL/resources" "$RES_PAY" "${GATEWAY_CURL_OPTS[@]}" -H "Authorization: $AUTH_GW" || true

    # Try to extract id from the response body first (useful when server returns 409 with body)
    rid="$(echo "$BODY" | jq -r '(.id // .existing_id // empty)')" || rid=""
    if [[ -z "${rid:-}" ]]; then
      if [[ "$CODE" =~ ^(200|201)$ ]]; then
        rid="$(echo "$BODY" | jq -r '.id // empty')"
      elif [[ "$CODE" == "409" ]]; then
        rid="$(lookup_resource_id "$R_NAME" "$R_URI")"
      fi
    fi

    if [[ -z "${rid:-}" ]]; then
      # one more try: list again, sometimes eventual consistency
      sleep 0.1
      rid="$(lookup_resource_id "$R_NAME" "$R_URI")"
    fi

    [[ -z "$rid" ]] && { echo "✖ Could not resolve numeric resource id for '$R_NAME'"; echo "  Response: $BODY"; exit 1; }

    RESOURCE_IDS+=( "$rid" )
    echo "✓ Resource upserted ($R_NAME → id=$rid) [HTTP $CODE]"
  done
fi

# 3) PROMPTS (optional) → numeric IDs
declare -a PROMPT_IDS=()
PR_COUNT="$(jq -r '(.mcp_registration.prompts // []) | length' "$TMP_MANIFEST")"
if [[ "$PR_COUNT" != "0" ]]; then
  for i in $(seq 0 $((PR_COUNT-1))); do
    P_ID="$(jq -r ".mcp_registration.prompts[$i].id // empty" "$TMP_MANIFEST")"
    P_NAME="$(jq -r ".mcp_registration.prompts[$i].name // empty" "$TMP_MANIFEST")"
    P_DESC="$(jq -r ".mcp_registration.prompts[$i].description // \"\"" "$TMP_MANIFEST")"
    P_TPL="$(jq -r  ".mcp_registration.prompts[$i].template // empty" "$TMP_MANIFEST")"

    PR_PAY="$(jq -nc --arg id "$P_ID" --arg name "$P_NAME" --arg desc "$P_DESC" --arg tpl "$P_TPL" '
      {name:$name, description:$desc, template:$tpl}
      + (if ($id|length)>0 then {id:$id} else {} end)
    ')"

    post_json "$GATEWAY_URL/prompts" "$PR_PAY" "${GATEWAY_CURL_OPTS[@]}" -H "Authorization: $AUTH_GW" || true

    pid="$(echo "$BODY" | jq -r '(.id // .existing_id // empty)')" || pid=""
    if [[ -z "${pid:-}" ]]; then
      if [[ "$CODE" =~ ^(200|201)$ ]]; then
        pid="$(echo "$BODY" | jq -r '.id // empty')"
      elif [[ "$CODE" == "409" ]]; then
        pid="$(lookup_prompt_id "$P_ID" "$P_NAME")"
      fi
    fi
    [[ -z "$pid" ]] && { echo "✖ Could not resolve numeric prompt id for '$P_NAME'"; exit 1; }

    PROMPT_IDS+=( "$pid" )
    echo "✓ Prompt upserted ($P_NAME → id=$pid) [HTTP $CODE]"
  done
fi

# 4) Federated Gateway (URL=/sse)
if [[ -n "${TOOL_ID:-}" ]]; then
  TOOLS_JSON="$(jq -n --arg t "$TOOL_ID" '[ $t ]')"
else
  TOOLS_JSON="[]"
fi

if [[ ${#RESOURCE_IDS[@]} -gt 0 ]]; then
  RIDS_JSON="$(printf '%s\n' "${RESOURCE_IDS[@]}" | jq -R . | jq -s 'map(tonumber)')"
else
  RIDS_JSON="[]"
fi

if [[ ${#PROMPT_IDS[@]} -gt 0 ]]; then
  PIDS_JSON="$(printf '%s\n' "${PROMPT_IDS[@]}"  | jq -R . | jq -s 'map(tonumber)')"
else
  PIDS_JSON="[]"
fi

GW_PAY="$(
  jq -n \
    --arg name    "$GW_NAME" \
    --arg desc    "$GW_DESC" \
    --arg url     "$SSE_URL" \
    --argjson tools "$TOOLS_JSON" \
    --argjson resources "$RIDS_JSON" \
    --argjson prompts "$PIDS_JSON" \
    '{
      name: $name,
      description: $desc,
      url: $url,
      associated_tools: $tools,
      associated_resources: $resources,
      associated_prompts: $prompts
    }'
)"

post_json "$GATEWAY_URL/gateways" "$GW_PAY" "${GATEWAY_CURL_OPTS[@]}" -H "Authorization: $AUTH_GW" || true
if [[ "$CODE" =~ ^(200|201|409)$ ]]; then
  echo "✓ Federated gateway upserted ($GW_NAME) [HTTP $CODE]"
else
  echo "✖ Gateway register failed ($CODE): $BODY" >&2; exit 1
fi

echo "✅ Done (registered in MCP-Gateway$( [[ -n "${HUB_URL:-}" ]] && echo ' and installed in Matrix Hub' ))."
