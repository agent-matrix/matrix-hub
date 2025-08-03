#!/usr/bin/env bash
# Add an MCP server to matrix/index.json and (optionally) push it to a running Hub.
# Usage (index only):
#   examples/add_mcp_server.sh --id hello-sse-server --version 0.1.0 \
#     --manifest-url "https://raw.githubusercontent.com/<user>/<repo>/<ref>/matrix/hello-server.manifest.json"
#
# Optional: also register in a Hub (remote → ingest → install) in one go:
#   HUB_URL=http://127.0.0.1:7300 ADMIN_TOKEN=... \
#   examples/add_mcp_server.sh --id hello-sse-server --version 0.1.0 \
#     --manifest-url "https://raw.githubusercontent.com/<user>/<repo>/<ref>/matrix/hello-server.manifest.json" \
#     --name "Hello World MCP (SSE)" --register

set -Eeuo pipefail

# -------- defaults / args ----------
ID=""
VERSION=""
NAME=""
SUMMARY=""
MANIFEST_URL=""
REGISTER=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --id) ID="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --summary) SUMMARY="$2"; shift 2 ;;
    --manifest-url) MANIFEST_URL="$2"; shift 2 ;;
    --register) REGISTER=1; shift ;;
    -h|--help)
      sed -n '1,40p' "$0"; exit 0 ;;
    *)
      echo "Unknown argument: $1"; exit 2 ;;
  esac
done

[[ -n "$ID" ]] || { echo "ERROR: --id is required"; exit 1; }
[[ -n "$VERSION" ]] || { echo "ERROR: --version is required"; exit 1; }
[[ -n "$MANIFEST_URL" ]] || { echo "ERROR: --manifest-url is required"; exit 1; }

# Ensure we are at repo root (where Makefile and scripts/init.py live)
if [[ ! -f "Makefile" || ! -f "scripts/init.py" ]]; then
  echo "ERROR: run from repo root (Makefile and scripts/init.py must exist)"; exit 1
fi

# -------- 1) Ensure empty index exists ----------
echo "▶ Ensuring matrix/index.json exists…"
make -s index-init

# -------- 2) Append/update this entity in index ----------
echo "▶ Adding/updating ${ID}@${VERSION} in matrix/index.json…"
python3 scripts/init.py add-url \
  --id "${ID}" \
  --version "${VERSION}" \
  ${NAME:+--name "${NAME}"} \
  ${SUMMARY:+--summary "${SUMMARY}"} \
  --manifest-url "${MANIFEST_URL}"

echo "✅ Index updated: matrix/index.json"

# -------- 3) Optional: register in a running Hub ----------
if [[ "$REGISTER" -eq 1 ]]; then
  : "${HUB_URL:?Set HUB_URL (e.g., http://127.0.0.1:7300)}"
  : "${ADMIN_TOKEN:?Set ADMIN_TOKEN}"

  # Detect route style (root vs /catalog) based on your Hub layout
  # Your project exposes /remotes and /ingest at root and /catalog/install under /catalog
  REMOTES_URL="${HUB_URL%/}/remotes"
  INGEST_URL="${HUB_URL%/}/ingest"
  INSTALL_URL="${HUB_URL%/}/catalog/install"

  echo "▶ Registering with Hub at ${HUB_URL} (remote → ingest → install)…"
  echo "→ POST ${REMOTES_URL}"
  curl -sS -X POST "${REMOTES_URL}" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"url\":\"${MANIFEST_URL%/matrix/*}/matrix/index.json\"}" \
    | jq -r '.' || true

  echo "→ POST ${INGEST_URL}"
  curl -sS -X POST "${INGEST_URL}" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"url\":\"${MANIFEST_URL%/matrix/*}/matrix/index.json\"}" \
    | jq -r '.' || true

  echo "→ POST ${INSTALL_URL}"
  UID="mcp_server:${ID}@${VERSION}"
  curl -sS -X POST "${INSTALL_URL}" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"id\":\"${UID}\",\"target\":\"./\"}" \
    | jq -r '.' || true

  echo "✅ Request sequence sent to Hub."
  echo "   If ingestion reports 'No compatible ingest function found', either:"
  echo "   - use /catalog/install with the manifest inline, or"
  echo "   - adjust index.json to the format expected by src/services/ingest.py."
fi
