#!/usr/bin/env bash
# examples/add_hello-sse-server.sh
#
# Add the Hello SSE server manifest to matrix/index.json (external catalog)
# and optionally push it into a running Matrix-Hub (DB) by invoking:
#   1) POST /remotes
#   2) POST /ingest
#   3) POST /catalog/install
#
# Usage (index only):
#   examples/add_hello-sse-server.sh
#
# Optional: also register into a running Hub (DB side):
#   HUB_URL=http://127.0.0.1:7300 ADMIN_TOKEN=... \
#   examples/add_hello-sse-server.sh --register
#
# Where ADMIN_TOKEN must match your Hub's API_TOKEN (if configured).

set -Eeuo pipefail

show_help() {
  cat <<'USAGE'
Usage:
  examples/add_hello-sse-server.sh [--register]

Description:
  Adds the Hello SSE server manifest URL to matrix/index.json using scripts/init.py.
  With --register, it will also call your Matrix-Hub to:
    1) add the remote index URL,
    2) trigger ingest, and
    3) install the entity (which performs mcp_registration on the gateway).

Environment (when using --register):
  HUB_URL      e.g., http://127.0.0.1:7300
  ADMIN_TOKEN  Admin API token for the Hub
USAGE
}

REGISTER=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --register) REGISTER=1; shift ;;
    -h|--help) show_help; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Constants for the Hello SSE server example
ID="hello-sse-server"
VERSION="0.1.0"
# NAME is unused here but kept for reference; not passed to init.py add-url
NAME="Hello World MCP (SSE)"
MANIFEST_URL="https://raw.githubusercontent.com/ruslanmv/hello-mcp/refs/heads/main/matrix/hello-server.manifest.json"

# Sanity: must run at repo root (Makefile + scripts/init.py present)
if [[ ! -f "Makefile" || ! -f "scripts/init.py" ]]; then
  echo "ERROR: run from repo root (Makefile and scripts/init.py must exist)" >&2
  exit 1
fi

echo "▶ Ensuring matrix/index.json exists…"
make -s index-init

echo "▶ Adding ${MANIFEST_URL} to matrix/index.json (Form B items.manifest_url)…"
python3 scripts/init.py add-url --manifest-url "${MANIFEST_URL}"

echo "✅ Index updated: matrix/index.json"

if [[ "${REGISTER}" -eq 1 ]]; then
  : "${HUB_URL:?Set HUB_URL (e.g., http://127.0.0.1:7300)}"
  : "${ADMIN_TOKEN:?Set ADMIN_TOKEN equal to the Hub's API_TOKEN}"

  # Derive the index URL (sibling of the manifest in /matrix/)
  INDEX_BASE="${MANIFEST_URL%/matrix/*}/matrix"
  INDEX_URL="${INDEX_BASE}/index.json"

  # Hub endpoints (your Hub exposes these at root)
  REMOTES_URL="${HUB_URL%/}/remotes"
  INGEST_URL="${HUB_URL%/}/ingest"
  INSTALL_URL="${HUB_URL%/}/catalog/install"

  echo "▶ Registering remote with Hub: ${INDEX_URL}"
  curl -fsS -X POST "${REMOTES_URL}" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$(jq -nc --arg url "${INDEX_URL}" '{url:$url}')" \
    || true

  echo "▶ Triggering ingest on Hub"
  curl -fsS -X POST "${INGEST_URL}" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$(jq -nc --arg url "${INDEX_URL}" '{url:$url}')" \
    || true

  echo "▶ Asking Hub to install (executes mcp_registration)"
  UID="mcp_server:${ID}@${VERSION}"
  curl -fsS -X POST "${INSTALL_URL}" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$(jq -nc --arg id "$UID" --arg target "./" '{id:$id, target:$target}')" \
    || true

  echo "✅ Requests sent to Hub. Check Hub logs for ingest/install results."
fi
