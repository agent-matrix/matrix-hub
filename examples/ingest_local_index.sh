#!/usr/bin/env bash
set -Eeuo pipefail

# Option C — process a local file-based index and install manifests via /catalog/install
# Also (optional) register Tool/Resources/Prompts/Gateway in MCP-Gateway.
# Outcome: Federated Gateway points to /sse (no /messages/ rewrite).

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── .env auto-discovery ───────────────────────────────────────────
find_env_up() {
  local dir="$1"
  while [[ -n "$dir" && "$dir" != "/" && "$dir" != "." ]]; do
    if [[ -f "$dir/.env" ]]; then
      echo "$dir/.env"; return 0
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

# ── Config ────────────────────────────────────────────────────────
FILE_INDEX="${FILE_INDEX:-examples/local_index.json}"   # relative to REPO_ROOT by default
TARGET_DIR="${TARGET_DIR:-./}"

# Matrix Hub (auto-detect http/https on 127.0.0.1:443)
HUB_URL="${HUB_URL:-${MATRIX_HUB_URL:-http://127.0.0.1:443}}"
HUB_TOKEN="${HUB_TOKEN:-${MATRIX_HUB_TOKEN:-}}"

# MCP-Gateway (optional — if set, also register directly)
GATEWAY_URL="${GATEWAY_URL:-${MCP_GATEWAY_URL:-}}"
GATEWAY_URL="${GATEWAY_URL%/admin}"
GATEWAY_URL="${GATEWAY_URL%/}"
GATEWAY_TOKEN="${GATEWAY_TOKEN:-${MCP_GATEWAY_TOKEN:-}}"

echo "ℹ️  REPO_ROOT: $REPO_ROOT"
echo "ℹ️  raw FILE_INDEX: $FILE_INDEX"

# ── Checks ────────────────────────────────────────────────────────
command -v jq >/dev/null 2>&1 || { echo "✖ jq is required"; exit 1; }
command -v python >/dev/null 2>&1 || { echo "✖ python is required"; exit 1; }

# Index absolute + base dir (resolve relative to REPO_ROOT)
ABS_INDEX_PATH="$(python - "$REPO_ROOT" "$FILE_INDEX" <<'PY'
import sys, pathlib
root = pathlib.Path(sys.argv[1]).expanduser().resolve()
idx  = pathlib.Path(sys.argv[2])
p = idx if idx.is_absolute() else (root / idx)
print(str(p.expanduser().resolve()))
PY
)"
[[ -f "$ABS_INDEX_PATH" ]] || { echo "✖ Index file not found: $ABS_INDEX_PATH"; exit 1; }

INDEX_BASE_DIR="$(python - "$ABS_INDEX_PATH" <<'PY'
import sys, pathlib
print(str(pathlib.Path(sys.argv[1]).expanduser().resolve().parent))
PY
)"

echo "ℹ️  Using local index file: $ABS_INDEX_PATH"
echo "ℹ️  INDEX_BASE_DIR: $INDEX_BASE_DIR"

# ── Helpers ───────────────────────────────────────────────────────
norm_auth() {
  local t="${1:-}"; [[ -z "$t" ]] && { echo ""; return; }
  local low; low="$(echo "$t" | tr '[:upper:]' '[:lower:]')"
  if [[ "$low" == bearer\ * || "$low" == basic\ * ]]; then echo "$t"; else echo "Bearer $t"; fi
}
post_json() {
  local url="$1"; shift
  local data="$1"; shift
  local -a args=( "$@" -H "Content-Type: application/json" )
  local tmp_body; tmp_body="$(mktemp)"
  CODE="$(curl -sS -w '%{http_code}' -o "$tmp_body" "${args[@]}" -X POST "$url" -d "$data")" || true
  BODY="$(cat "$tmp_body")"; rm -f "$tmp_body"
  echo "      ↳ POST $url  → HTTP $CODE"
  [[ "$CODE" =~ ^(200|201)$ ]] || [[ "$CODE" == "409" ]] || echo "        Body: $BODY"
}
get_json() {
  local url="$1"; shift
  local -a args=( "$@" -H "Accept: application/json" )
  BODY="$(curl -sS "${args[@]}" "$url")" || BODY=""
  CODE=200
  echo "      ↳ GET  $url  → HTTP $CODE"
}
parse_list() {
  jq -c 'if type=="array" then . else ( .items? // .data? // [] ) end'
}
lookup_resource_id() {
  local gw_url="$1" gw_auth="$2" name="$3" uri="$4"
  get_json "$gw_url/resources" "${GATEWAY_CURL_OPTS[@]}" -H "Authorization: $gw_auth"
  echo "$BODY" | parse_list | jq -r --arg n "$name" --arg u "$uri" '
    map(select(
      (.name|tostring|ascii_downcase)==($n|ascii_downcase)
      or (.uri|tostring)==$u
      or ((.id|tostring)==$n)
    ))| (.[0].id // empty)
  ' | head -n1
}
lookup_prompt_id() {
  local gw_url="$1" gw_auth="$2" pid="$3" name="$4"
  get_json "$gw_url/prompts" "${GATEWAY_CURL_OPTS[@]}" -H "Authorization: $gw_auth"
  echo "$BODY" | parse_list | jq -r --arg i "$pid" --arg n "$name" '
    map(select( ((.id|tostring)==$i) or ((.name|tostring|ascii_downcase)==($n|ascii_downcase)) )) | (.[0].id // empty)
  ' | head -n1
}

# ── Matrix Hub URL: autodetect http/https on :443 ─────────────────
HUB_URL="${HUB_URL%/}"
if [[ "$HUB_URL" == 127.0.0.1:443 ]]; then HUB_URL="http://127.0.0.1:443"; fi
if [[ "$HUB_URL" == http://127.0.0.1:443 || "$HUB_URL" == https://127.0.0.1:443 ]]; then
  if curl -k -sS -I --max-time 2 "https://127.0.0.1:443/health" >/dev/null 2>&1; then
    HUB_URL="https://127.0.0.1:443"; HUB_CURL_OPTS=(-k)
  elif curl -sS -I --max-time 2 "http://127.0.0.1:443/health" >/dev/null 2>&1; then
    HUB_URL="http://127.0.0.1:443"; HUB_CURL_OPTS=()
  else
    HUB_CURL_OPTS=()
  fi
else
  [[ "$HUB_URL" == https:* ]] && HUB_CURL_OPTS=(-k) || HUB_CURL_OPTS=()
fi
HUB_AUTH_HDR=()
if [[ -n "${HUB_TOKEN:-}" ]]; then HUB_AUTH_HDR=(-H "Authorization: $(norm_auth "$HUB_TOKEN")"); fi
echo "ℹ️  HUB_URL resolved to: $HUB_URL"

# ── MCP-Gateway curl opts (optional block) ────────────────────────
if [[ -n "${GATEWAY_URL:-}" && -n "${GATEWAY_TOKEN:-}" ]]; then
  [[ "$GATEWAY_URL" == https:* ]] && GATEWAY_CURL_OPTS=(-k) || GATEWAY_CURL_OPTS=()
  GW_AUTH="$(norm_auth "$GATEWAY_TOKEN")"
  echo "ℹ️  MCP-Gateway direct registration enabled at $GATEWAY_URL"
else
  GW_AUTH=""
  echo "ℹ️  MCP-Gateway direct registration disabled (missing MCP_GATEWAY_URL or token)."
fi

# ── Read index (manifests array) ──────────────────────────────────
readarray -t RAW_MANIFESTS < <(jq -r '
  if (.manifests|type=="array") then .manifests[]
  elif (.items|type=="array") then .items[].manifest_url
  elif (.entries|type=="array") then (.entries[] | ( (.base_url//"") + (.path//"") ))
  else empty end
' "$ABS_INDEX_PATH")

if (( ${#RAW_MANIFESTS[@]} == 0 )); then
  echo "✖ No manifest URLs found in index: $ABS_INDEX_PATH"; exit 1
fi
echo "ℹ️  Found ${#RAW_MANIFESTS[@]} manifest ref(s) in index"

# ── Utility: resolve refs first against REPO_ROOT, then index dir ─
trim_cr(){ tr -d '\r'; }
resolve_ref() {
  local raw; raw="$(echo -n "$1" | trim_cr)"
  echo "  • raw ref: $raw"
  if [[ -z "$raw" || "$raw" == "null" ]]; then echo ""; return 0; fi
  if [[ "$raw" =~ ^https?:// ]]; then echo "http|$raw"; return 0; fi
  if [[ "$raw" =~ ^file:// ]]; then echo "file|${raw#file://}"; return 0; fi
  if [[ "$raw" =~ ^/ ]]; then echo "file|$raw"; return 0; fi

  # try REPO_ROOT first
  local abs_repo; abs_repo="$(python - "$REPO_ROOT" "$raw" <<'PY'
import sys, pathlib
root = pathlib.Path(sys.argv[1])
raw  = pathlib.Path(sys.argv[2])
print(str((root / raw).expanduser().resolve()))
PY
)"
  if [[ -f "$abs_repo" ]]; then
    echo "file|$abs_repo"; return 0
  fi

  # then fallback to index base dir
  local abs_idx; abs_idx="$(python - "$INDEX_BASE_DIR" "$raw" <<'PY'
import sys, pathlib
base = pathlib.Path(sys.argv[1])
raw  = pathlib.Path(sys.argv[2])
print(str((base / raw).expanduser().resolve()))
PY
)"
  echo "file|$abs_idx"
}

load_manifest_json() {
  local mtype="$1" mval="$2"
  if [[ "$mtype" == "http" ]]; then curl -fsSL "$mval"
  else [[ -f "$mval" ]] && cat "$mval" || return 1
  fi
}

# ── Process each manifest ─────────────────────────────────────────
for RAW in "${RAW_MANIFESTS[@]}"; do
  OUT="$(resolve_ref "$RAW")"
  if [[ -z "$OUT" ]]; then echo "⚠️  Skipping empty/invalid manifest ref: '$RAW'"; continue; fi
  MTYPE="${OUT%%|*}"; MVAL="${OUT#*|}"

  if [[ "$MTYPE" == "http" ]]; then
    echo "▶️  Manifest (http): $MVAL"
  else
    echo "▶️  Manifest (file): file://$MVAL"
  fi

  MANIFEST="$(load_manifest_json "$MTYPE" "$MVAL" || true)"
  if [[ -z "$MANIFEST" ]]; then
    echo "    ✖ Failed to load manifest ($MTYPE): $MVAL"
    continue
  fi

  ENTITY_UID="$(jq -r '"\(.type):\(.id)@\(.version)"' <<<"$MANIFEST")"
  BASE_URL="$(jq -r '.mcp_registration.server.url // empty' <<<"$MANIFEST")"
  echo "    uid: $ENTITY_UID"
  echo "    base server url: ${BASE_URL:-<none>}"

  if [[ -z "$ENTITY_UID" || "$ENTITY_UID" == "null:null@null" || "$ENTITY_UID" == *"null"* ]]; then
    echo "    ⚠️  Skipping: invalid uid in manifest"; continue
  fi
  if [[ -z "$BASE_URL" || "$BASE_URL" == "null" ]]; then
    echo "    ⚠️  Skipping: manifest missing .mcp_registration.server.url"; continue
  fi

  BASE_URL="${BASE_URL%/}"; SSE_URL="${BASE_URL}/sse"

  # Gentle SSE preflight (non-fatal)
  set +e +o pipefail
  status="$(curl -sS -I --connect-timeout 1 --max-time 2 "$SSE_URL" 2>/dev/null | head -n1 | awk '{print $2}')"
  if [[ -z "${status:-}" ]]; then
    status="$(curl -sS -N --connect-timeout 1 --max-time 2 -D- -o /dev/null "$SSE_URL" 2>/dev/null | head -n1 | awk '{print $2}')"
  fi
  set -e -o pipefail
  [[ "${status:-}" =~ ^2[0-9][0-9]$ ]] && echo "    ⏱ SSE preflight ok (HTTP $status)" || echo "    ⏱ SSE preflight non-2xx (${status:-timeout}) — continuing"

  # Patch: force /sse and drop transport
  PATCHED="$(jq --arg url "$SSE_URL" '
    . as $root
    | ($root
       | .mcp_registration.server.url = $url
       | if .mcp_registration.server.transport then del(.mcp_registration.server.transport) else . end
      )
  ' <<<"$MANIFEST")"

  # Install into Matrix Hub
  echo "    📦 Installing $ENTITY_UID via $HUB_URL/catalog/install"
  post_json "$HUB_URL/catalog/install" \
    "$(jq -nc --arg id "$ENTITY_UID" --arg target "$TARGET_DIR" --argjson manifest "$PATCHED" '{id:$id, target:$target, manifest:$manifest}')" \
    "${HUB_CURL_OPTS[@]}" "${HUB_AUTH_HDR[@]}"
  if [[ "$CODE" =~ ^(200|201)$ ]]; then
    echo "    ✅ Hub install ok"
  else
    echo "    ⚠ Hub install HTTP $CODE — continuing"
  fi

  # Optional: direct MCP-Gateway registration
  if [[ -n "${GATEWAY_URL:-}" && -n "${GATEWAY_TOKEN:-}" ]]; then
    echo "    🔗 Registering in MCP-Gateway ($GATEWAY_URL)"
    [[ "$GATEWAY_URL" == https:* ]] && GATEWAY_CURL_OPTS=(-k) || GATEWAY_CURL_OPTS=()
    GW_AUTH="$(norm_auth "$GATEWAY_TOKEN")"

    TOOL_ID="$(jq -r '.mcp_registration.tool.id // empty' <<<"$PATCHED")"
    TOOL_NAME="$(jq -r '.mcp_registration.tool.name // empty' <<<"$PATCHED")"
    TOOL_DESC="$(jq -r '.mcp_registration.tool.description // ""' <<<"$PATCHED")"
    [[ -z "$TOOL_NAME" && -n "$TOOL_ID" ]] && TOOL_NAME="$TOOL_ID"

    # 1) Tool (idempotent)
    if [[ -n "${TOOL_ID:-}" || -n "${TOOL_NAME:-}" ]]; then
      TOOL_PAY="$(jq -nc --arg id "${TOOL_ID:-}" --arg name "${TOOL_NAME:-tool}" --arg desc "${TOOL_DESC:-}" '
        {name:$name, description:$desc, integration_type:"MCP", request_type:"SSE"}
        + (if ($id|length)>0 then {id:$id} else {} end)
      ')"
      post_json "$GATEWAY_URL/tools" "$TOOL_PAY" "${GATEWAY_CURL_OPTS[@]}" -H "Authorization: $GW_AUTH" || true
      if [[ "$CODE" =~ ^(200|201|409)$ ]]; then
        echo "    ✓ Tool upserted (${TOOL_ID:-$TOOL_NAME}) [HTTP $CODE]"
      else
        echo "    ✖ Tool failed ($CODE): $BODY"; continue
      fi
    fi

    # 2) Resources (need numeric ids)
    declare -a RESOURCE_IDS=()
    RES_COUNT="$(jq -r '(.mcp_registration.resources // []) | length' <<<"$PATCHED")"
    if [[ "$RES_COUNT" != "0" ]]; then
      for i in $(seq 0 $((RES_COUNT-1))); do
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
        post_json "$GATEWAY_URL/resources" "$RES_PAY" "${GATEWAY_CURL_OPTS[@]}" -H "Authorization: $GW_AUTH" || true
        rid="$(echo "$BODY" | jq -r '(.id // .existing_id // empty)')" || rid=""
        if [[ -z "${rid:-}" ]]; then
          if [[ "$CODE" =~ ^(200|201)$ ]]; then
            rid="$(echo "$BODY" | jq -r '.id // empty')"
          elif [[ "$CODE" == "409" ]]; then
            rid="$(lookup_resource_id "$GATEWAY_URL" "$GW_AUTH" "$R_NAME" "$R_URI")"
          fi
        fi
        if [[ -z "${rid:-}" ]]; then
          sleep 0.1
          rid="$(lookup_resource_id "$GATEWAY_URL" "$GW_AUTH" "$R_NAME" "$R_URI")"
        fi
        if [[ -z "$rid" ]]; then
          echo "    ✖ Could not resolve numeric resource id for '$R_NAME'"; echo "      Resp: $BODY"; continue 2
        fi
        RESOURCE_IDS+=( "$rid" )
        echo "    ✓ Resource upserted ($R_NAME → id=$rid) [HTTP $CODE]"
      done
    fi

    # 3) Prompts (optional) → numeric ids
    declare -a PROMPT_IDS=()
    PR_COUNT="$(jq -r '(.mcp_registration.prompts // []) | length' <<<"$PATCHED")"
    if [[ "$PR_COUNT" != "0" ]]; then
      for i in $(seq 0 $((PR_COUNT-1))); do
        P_ID="$(jq -r ".mcp_registration.prompts[$i].id // empty" <<<"$PATCHED")"
        P_NAME="$(jq -r ".mcp_registration.prompts[$i].name // empty" <<<"$PATCHED")"
        P_DESC="$(jq -r ".mcp_registration.prompts[$i].description // \"\"" <<<"$PATCHED")"
        P_TPL="$(jq -r  ".mcp_registration.prompts[$i].template // empty" <<<"$PATCHED")"
        PR_PAY="$(jq -nc --arg id "$P_ID" --arg name "$P_NAME" --arg desc "$P_DESC" --arg tpl "$P_TPL" '
          {name:$name, description:$desc, template:$tpl}
          + (if ($id|length)>0 then {id:$id} else {} end)
        ')"
        post_json "$GATEWAY_URL/prompts" "$PR_PAY" "${GATEWAY_CURL_OPTS[@]}" -H "Authorization: $GW_AUTH" || true
        pid="$(echo "$BODY" | jq -r '(.id // .existing_id // empty)')" || pid=""
        if [[ -z "${pid:-}" ]]; then
          if [[ "$CODE" =~ ^(200|201)$ ]]; then
            pid="$(echo "$BODY" | jq -r '.id // empty')"
          elif [[ "$CODE" == "409" ]]; then
            pid="$(lookup_prompt_id "$GATEWAY_URL" "$GW_AUTH" "$P_ID" "$P_NAME")"
          fi
        fi
        if [[ -z "$pid" ]]; then echo "    ✖ Could not resolve numeric prompt id for '$P_NAME'"; continue 2; fi
        PROMPT_IDS+=( "$pid" )
        echo "    ✓ Prompt upserted ($P_NAME → id=$pid) [HTTP $CODE]"
      done
    fi

    # 4) Federated Gateway → /sse
    if [[ -n "${TOOL_ID:-}" ]]; then TOOLS_JSON="$(jq -n --arg t "$TOOL_ID" '[ $t ]')"; else TOOLS_JSON="[]"; fi
    if [[ ${#RESOURCE_IDS[@]} -gt 0 ]]; then
      RIDS_JSON="$(printf '%s\n' "${RESOURCE_IDS[@]}" | jq -R . | jq -s 'map(tonumber)')"
    else RIDS_JSON="[]"; fi
    if [[ ${#PROMPT_IDS[@]} -gt 0 ]]; then
      PIDS_JSON="$(printf '%s\n' "${PROMPT_IDS[@]}" | jq -R . | jq -s 'map(tonumber)')"
    else PIDS_JSON="[]"; fi

    GW_NAME="$(jq -r '.mcp_registration.server.name // "watsonx-mcp"' <<<"$PATCHED")"
    GW_DESC="$(jq -r '.mcp_registration.server.description // ""' <<<"$PATCHED")"
    GW_PAY="$(
      jq -n --arg name "$GW_NAME" --arg desc "$GW_DESC" --arg url "$SSE_URL" \
            --argjson tools "$TOOLS_JSON" --argjson resources "$RIDS_JSON" --argjson prompts "$PIDS_JSON" '
        {name:$name, description:$desc, url:$url,
         associated_tools:$tools, associated_resources:$resources, associated_prompts:$prompts}'
    )"
    post_json "$GATEWAY_URL/gateways" "$GW_PAY" "${GATEWAY_CURL_OPTS[@]}" -H "Authorization: $GW_AUTH" || true
    if [[ "$CODE" =~ ^(200|201|409)$ ]]; then
      echo "    ✓ Federated gateway upserted ($GW_NAME) [HTTP $CODE]"
    else
      echo "    ✖ Gateway register failed ($CODE): $BODY"
    fi
  fi

done

echo "✅ All manifests processed from local index."
