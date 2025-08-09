#!/usr/bin/env bash
set -euo pipefail

# Option A — install using a local manifest file (no HTTP hosting needed)
# This version:
#  - Forces the SSE endpoint to /sse (so Hub won't rewrite it to /messages/)
#  - Removes 'transport' to avoid Hub normalization
#  - Preflights the SSE endpoint to prevent 502 during gateway registration

HUB_URL="${HUB_URL:-http://127.0.0.1:7300}"
MANIFEST_PATH="${MANIFEST_PATH:-examples/manifests/watsonx.manifest.json}"
ENTITY_UID="${ENTITY_UID:-mcp_server:watsonx-agent@0.1.0}"
TARGET_DIR="${TARGET_DIR:-./}"
TMP_MANIFEST="$(mktemp -t watsonx_manifest.XXXXXX.json)"

cleanup() { rm -f "$TMP_MANIFEST" 2>/dev/null || true; }
trap cleanup EXIT

command -v jq >/dev/null 2>&1 || { echo "✖ jq is required"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "✖ curl is required"; exit 1; }
[[ -f "$MANIFEST_PATH" ]] || { echo "✖ Manifest not found: $MANIFEST_PATH"; exit 1; }

# 1) Load manifest & compute SSE URL (ensure it ends with /sse)
BASE_URL="$(jq -r '.mcp_registration.server.url // empty' "$MANIFEST_PATH")"
if [[ -z "$BASE_URL" ]]; then
  echo "✖ No .mcp_registration.server.url in manifest"
  exit 1
fi
# normalize: strip trailing slashes, then append /sse
BASE_URL="${BASE_URL%/}"
SSE_URL="${BASE_URL}/sse"

# 2) Preflight the SSE endpoint (avoid 502 from gateway)
echo "▶️ Preflight SSE: $SSE_URL"
if ! curl -sS -N --max-time 2 -D- -o /dev/null "$SSE_URL" | head -n1 | grep -qE "HTTP/[0-9.]+ 200|HTTP/[0-9.]+ 2[0-9][0-9]"; then
  echo "⚠️ SSE preflight did not return 2xx. Ensure your server is running:"
  echo "   python server.py   # should listen on $SSE_URL"
  # continue anyway; some SSE servers only open stream on first event
fi

# 3) Create a patched manifest on-the-fly:
#    - set server.url to .../sse
#    - remove server.transport (so Hub won't rewrite to /messages/)
jq \
  --arg url "$SSE_URL" '
    . as $root
    | ($root
       | .mcp_registration.server.url = $url
       | if .mcp_registration.server.transport then
           del(.mcp_registration.server.transport)
         else .
         end
      )
  ' "$MANIFEST_PATH" > "$TMP_MANIFEST"

echo "▶️ Installing $ENTITY_UID via $HUB_URL/catalog/install using patched manifest"
curl -sS -X POST "$HUB_URL/catalog/install" \
  -H "Content-Type: application/json" \
  -d "$(jq -nc \
        --arg id "$ENTITY_UID" \
        --arg target "$TARGET_DIR" \
        --argjson manifest "$(cat "$TMP_MANIFEST")" \
        '{id:$id, target:$target, manifest:$manifest}')" \
  | jq .

echo "✅ Done."
