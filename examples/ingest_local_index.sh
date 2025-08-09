#!/usr/bin/env bash
set -euo pipefail

# Option C — process a local file-based index and install manifests via /catalog/install
# Works with file paths or http(s) URLs inside the index.
# Outcome: Federated Gateway registered against /sse, transport removed.

HUB_URL="${HUB_URL:-http://127.0.0.1:7300}"
FILE_INDEX="${FILE_INDEX:-examples/local_index.json}"   # local index file (relative to REPO_ROOT)
TARGET_DIR="${TARGET_DIR:-./}"

command -v jq >/dev/null 2>&1 || { echo "✖ jq is required"; exit 1; }
command -v python >/dev/null 2>&1 || { echo "✖ python is required"; exit 1; }
[[ -f "$FILE_INDEX" ]] || { echo "✖ Index file not found: $FILE_INDEX"; exit 1; }

# Determine the repository root, assuming the script is run from there.
# This ensures manifest paths in local_index.json are resolved correctly.
REPO_ROOT="$(pwd)"

# Make absolute path for the index file for informational purposes
ABS_INDEX_PATH="$(python - "$REPO_ROOT" "$FILE_INDEX" <<'PY'
import sys, pathlib
base = pathlib.Path(sys.argv[1])
file_index = sys.argv[2]
p = (base / file_index).expanduser().resolve()
print(str(p))
PY
)"

echo "ℹ️ Using local index file: $ABS_INDEX_PATH"

# Read manifest refs from index (supports several layouts)
readarray -t RAW_MANIFESTS < <(jq -r '
  if (.manifests|type=="array") then .manifests[]
  elif (.items|type=="array") then .items[].manifest_url
  elif (.entries|type=="array") then (.entries[] | ( (.base_url//"") + (.path//"") ))
  else empty end
' "$ABS_INDEX_PATH")

if (( ${#RAW_MANIFESTS[@]} == 0 )); then
  echo "✖ No manifest URLs found in index: $ABS_INDEX_PATH"
  exit 1
fi

# Trim CRs just in case (Windows files)
trim_cr() { tr -d '\r'; }

# Resolve a manifest reference to a single line: TYPE|VALUE
# TYPE ∈ {http,file}; VALUE is URL or absolute file path
resolve_ref() {
  local raw
  raw="$(echo -n "$1" | trim_cr)"
  if [[ -z "$raw" || "$raw" == "null" ]]; then
    echo ""
    return 0
  fi
  if [[ "$raw" =~ ^https?:// ]]; then
    echo "http|$raw"; return 0
  fi
  if [[ "$raw" =~ ^file:// ]]; then
    echo "file|${raw#file://}"; return 0
  fi
  # treat as path relative to the REPO_ROOT (where the script is executed)
  local abs
  abs="$(python - "$REPO_ROOT" "$raw" <<'PY'
import sys, pathlib
base = pathlib.Path(sys.argv[1]) # This is the REPO_ROOT
raw  = sys.argv[2]
print(str((base / raw).resolve()))
PY
)"
  echo "file|$abs"
}

# Load a manifest as JSON string (from http or file)
load_manifest_json() {
  local mtype="$1" mval="$2"
  if [[ "$mtype" == "http" ]]; then
    curl -fsSL "$mval"
  else
    [[ -f "$mval" ]] || { echo ""; return 1; }
    cat "$mval"
  fi
}

# Process each manifest entry
for RAW in "${RAW_MANIFESTS[@]}"; do
  OUT="$(resolve_ref "$RAW")"
  if [[ -z "$OUT" ]]; then
    echo "⚠️ Skipping empty/invalid manifest ref: '$RAW'"
    continue
  fi
  MTYPE="${OUT%%|*}"
  MVAL="${OUT#*|}"

  if [[ "$MTYPE" == "http" ]]; then
    echo "▶️ Processing manifest (http): $MVAL"
  else
    echo "▶️ Processing manifest (file): file://$MVAL"
  fi

  MANIFEST="$(load_manifest_json "$MTYPE" "$MVAL" || true)"
  if [[ -z "$MANIFEST" ]]; then
    echo "    ✖ Failed to load manifest ($MTYPE): $MVAL"
    continue
  fi

  # Compute UID and patch SSE endpoint
  ENTITY_UID="$(jq -r '"\(.type):\(.id)@\(.version)"' <<<"$MANIFEST")"
  BASE_URL="$(jq -r '.mcp_registration.server.url // empty' <<<"$MANIFEST")"
  if [[ -z "$ENTITY_UID" || "$ENTITY_UID" == "null:null@null" || "$ENTITY_UID" == *"null"* ]]; then
    echo "    ⚠️ Skipping: invalid uid in manifest"; continue
  fi
  if [[ -z "$BASE_URL" || "$BASE_URL" == "null" ]]; then
    echo "    ⚠️ Skipping: manifest missing .mcp_registration.server.url"; continue
  fi
  BASE_URL="${BASE_URL%/}"
  SSE_URL="${BASE_URL}/sse"

  # Patch: force /sse and drop transport to avoid /messages/ rewrite
  PATCHED="$(jq --arg url "$SSE_URL" '
      . as $root
      | ($root
         | .mcp_registration.server.url = $url
         | if .mcp_registration.server.transport then del(.mcp_registration.server.transport) else . end
        )
  ' <<<"$MANIFEST")"

  echo "    📦 Installing $ENTITY_UID via $HUB_URL/catalog/install"
  curl -sS -X POST "$HUB_URL/catalog/install" \
    -H "Content-Type: application/json" \
    -d "$(jq -nc \
           --arg id "$ENTITY_UID" \
           --arg target "$TARGET_DIR" \
           --argjson manifest "$PATCHED" \
           '{id:$id, target:$target, manifest:$manifest}')" \
    | jq -r 'if .results then "    ✅ install ok" else . end'
done

echo "✅ All manifests processed from local index."
