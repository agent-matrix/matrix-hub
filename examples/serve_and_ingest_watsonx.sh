#!/usr/bin/env bash
set -euo pipefail

# Option B — serve repo via localhost HTTP and "ingest" a remote index.json
# This script:
#  1) Serves your repo locally (python -m http.server)
#  2) Fetches examples/index.json
#  3) Extracts manifest URLs (supports several index shapes)
#  4) For each manifest:
#       - loads it
#       - forces server.url to .../sse and removes server.transport
#       - POSTs to Matrix Hub /catalog/install (equivalent to ingest+install)
#
# Requires: jq, curl, python

HUB_URL="${HUB_URL:-http://127.0.0.1:443}"
SERVE_DIR="${SERVE_DIR:-.}"                 # repo root that contains /examples/...
PORT="${PORT:-8000}"
INDEX_PATH_REL="${INDEX_PATH_REL:-examples/index.json}"
INDEX_URL="http://127.0.0.1:${PORT}/${INDEX_PATH_REL}"
TARGET_DIR="${TARGET_DIR:-./}"

command -v jq >/dev/null 2>&1 || { echo "✖ jq is required"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "✖ curl is required"; exit 1; }
command -v python >/dev/null 2>&1 || { echo "✖ python is required"; exit 1; }

# 1) Start a simple static server in background
echo "▶️ Serving ${SERVE_DIR} at http://127.0.0.1:${PORT}/"
pushd "$SERVE_DIR" >/dev/null
python -m http.server "$PORT" >/dev/null 2>&1 &
SERVER_PID=$!
popd >/dev/null

cleanup() {
  echo "⏹ Stopping local server (pid $SERVER_PID)"
  kill "$SERVER_PID" 2>/dev/null || true
}
trap cleanup EXIT

# 2) Wait for server & index to be reachable
for i in {1..40}; do
  if curl -fsS -o /dev/null "$INDEX_URL"; then
    echo "✔ Found index at $INDEX_URL"
    break
  fi
  echo "… waiting for server ($i/40)"
  sleep 0.25
done

# 3) Fetch index JSON
INDEX_JSON="$(curl -fsSL "$INDEX_URL")" || { echo "✖ Could not fetch $INDEX_URL"; exit 1; }

# 4) Extract manifest URLs (supports multiple layouts)
readarray -t RAW_MANIFESTS < <(jq -r '
  if (.manifests|type=="array") then .manifests[]
  elif (.items|type=="array") then .items[].manifest_url
  elif (.entries|type=="array") then (.entries[] | "\(.base_url)\(.path)")
  else empty end
' <<< "$INDEX_JSON")

if (( ${#RAW_MANIFESTS[@]} == 0 )); then
  echo "✖ No manifest URLs found in $INDEX_URL"
  exit 1
fi

echo "🔎 Found ${#RAW_MANIFESTS[@]} manifest(s) in index"

# Helper: resolve relative URLs against the index URL
resolve_url() {
  python - "$INDEX_URL" "$1" <<'PY'
import sys
from urllib.parse import urljoin
print(urljoin(sys.argv[1], sys.argv[2]))
PY
}

# 5) Process each manifest
for RAW in "${RAW_MANIFESTS[@]}"; do
  MURL="$(resolve_url "$RAW")"
  echo "▶️ Fetching manifest: $MURL"

  MANIFEST="$(curl -fsSL "$MURL")" || { echo "✖ Failed to fetch manifest $MURL"; continue; }

  # Compute ENTITY_UID and SSE URL
  ENTITY_UID="$(jq -r '"\(.type):\(.id)@\(.version)"' <<<"$MANIFEST")"
  BASE_URL="$(jq -r '.mcp_registration.server.url // empty' <<<"$MANIFEST")"
  if [[ -z "$BASE_URL" ]]; then
    echo "⚠️ Skipping (no server.url): $MURL"
    continue
  fi
  BASE_URL="${BASE_URL%/}"
  SSE_URL="${BASE_URL}/sse"

  # Optional: preflight SSE (non-fatal for SSE streams)
  echo "   ⏱ Preflight SSE: $SSE_URL"
  curl -sS -N --max-time 2 -D- -o /dev/null "$SSE_URL" >/dev/null 2>&1 || true

  # Patch: set url=.../sse and remove transport to avoid /messages/ rewrite
  PATCHED="$(jq --arg url "$SSE_URL" '
     . as $root
     | ($root
        | .mcp_registration.server.url = $url
        | if .mcp_registration.server.transport then del(.mcp_registration.server.transport) else . end
       )
  ' <<<"$MANIFEST")"

  echo "   📦 Installing $ENTITY_UID via $HUB_URL/catalog/install"
  curl -sS -X POST "$HUB_URL/catalog/install" \
    -H "Content-Type: application/json" \
    -d "$(jq -nc \
          --arg id "$ENTITY_UID" \
          --arg target "$TARGET_DIR" \
          --argjson manifest "$PATCHED" \
          '{id:$id, target:$target, manifest:$manifest}')" \
    | jq -r 'if .results then "   ✅ install ok" else . end'
done

echo "✅ All manifests processed."
