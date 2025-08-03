#!/usr/bin/env bash
# examples/add_mcp_server.sh
#
# Add an MCP server to matrix/index.json and (optionally) push it into a running Matrix-Hub.
# Index step: writes to your external catalog (matrix/index.json).
# Hub step: calls Hub APIs so the server is ingested into the DB, then installed (mcp_registration).
#
# Usage (index only):
#   examples/add_mcp_server.sh \
#     --manifest-url "https://raw.githubusercontent.com/<user>/<repo>/<ref>/matrix/<file>.manifest.json"
#
# Optional: also persist in the Hub DB (auto-discovers id/version from the manifest if omitted):
#   HUB_URL=http://127.0.0.1:7300 ADMIN_TOKEN=... \
#   examples/add_mcp_server.sh \
#     --manifest-url "https://raw.githubusercontent.com/<user>/<repo>/<ref>/matrix/<file>.manifest.json" \
#     [--id hello-sse-server] [--version 0.1.0] --register
#
# Where ADMIN_TOKEN must match the Hub's API_TOKEN (if configured).

set -Eeuo pipefail

show_help() {
  cat <<'USAGE'
Usage:
  examples/add_mcp_server.sh --manifest-url <URL> [--register] [--id <id>] [--version <ver>] [--name <name>] [--summary <txt>]

Description:
  - Always updates matrix/index.json via scripts/init.py add-url (index-only flow).
  - If --register is passed, it will:
      1) POST /remotes with the derived index URL
      2) POST /ingest  for that URL
      3) POST /catalog/install with UID mcp_server:<id>@<version>
    If --id/--version are not provided, they are read from the remote manifest.

Environment (when using --register):
  HUB_URL      e.g., http://127.0.0.1:7300
  ADMIN_TOKEN  Admin API token for the Hub

Examples:
  # Index only
  examples/add_mcp_server.sh --manifest-url "https://raw.githubusercontent.com/user/repo/ref/matrix/hello-server.manifest.json"

  # Index + register (auto-discover id/version)
  HUB_URL=http://127.0.0.1:7300 ADMIN_TOKEN=xyz \
  examples/add_mcp_server.sh --manifest-url "https://.../matrix/hello-server.manifest.json" --register

  # Index + register (explicit id/version)
  HUB_URL=http://127.0.0.1:7300 ADMIN_TOKEN=xyz \
  examples/add_mcp_server.sh --manifest-url "https://.../matrix/hello-server.manifest.json" \
    --id hello-sse-server --version 0.1.0 --register
USAGE
}

# -------- defaults / args ----------
ID=""
VERSION=""
NAME=""
SUMMARY=""
MANIFEST_URL=""
REGISTER=0

# Default manifest URL (hello SSE example); can be overridden by --manifest-url
DEFAULT_MANIFEST_URL="https://raw.githubusercontent.com/ruslanmv/hello-mcp/refs/heads/main/matrix/hello-server.manifest.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --id) ID="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --summary) SUMMARY="$2"; shift 2 ;;
    --manifest-url) MANIFEST_URL="$2"; shift 2 ;;
    --register) REGISTER=1; shift ;;
    -h|--help) show_help; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2; echo; show_help; exit 2 ;;
  esac
done

# Fallback to a safe public example if --manifest-url is omitted
if [[ -z "$MANIFEST_URL" ]]; then
  MANIFEST_URL="$DEFAULT_MANIFEST_URL"
  echo "ℹ️  --manifest-url not provided; using default example:"
  echo "   $MANIFEST_URL"
fi

# Ensure repo root
if [[ ! -f "Makefile" || ! -f "scripts/init.py" ]]; then
  echo "ERROR: run from repo root (Makefile and scripts/init.py must exist)" >&2
  exit 1
fi

# -------- 1) Ensure empty index exists ----------
echo "▶ Ensuring matrix/index.json exists…"
make -s index-init

# -------- 2) Append/update this entity in index ----------
echo "▶ Adding ${MANIFEST_URL} to matrix/index.json (Form B items.manifest_url)…"
python3 scripts/init.py add-url --manifest-url "${MANIFEST_URL}"
echo "✅ Index updated: matrix/index.json"

# -------- 3) Optional: register in a running Hub (DB) ----------
if [[ "$REGISTER" -eq 1 ]]; then
  : "${HUB_URL:?Set HUB_URL (e.g., http://127.0.0.1:7300)}"
  : "${ADMIN_TOKEN:?Set ADMIN_TOKEN equal to the Hub's API_TOKEN}"

  # If ID/VERSION are missing, discover them from the manifest.
  if [[ -z "$ID" || -z "$VERSION" ]]; then
    command -v jq >/dev/null || { echo "ERROR: jq is required to auto-discover id/version from the manifest." >&2; exit 1; }
    echo "→ Discovering id/version from manifest: ${MANIFEST_URL}"
    MAN_JSON="$(curl -fsSL "${MANIFEST_URL}")" || { echo "ERROR: could not fetch manifest_url" >&2; exit 1; }
    TYPE="$(jq -r '.type // empty' <<<"$MAN_JSON")"
    [[ "$TYPE" == "mcp_server" ]] || { echo "ERROR: manifest type must be 'mcp_server', got '${TYPE:-<empty>}'" >&2; exit 1; }
    ID="${ID:-$(jq -r '.id // empty' <<<"$MAN_JSON")}"
    VERSION="${VERSION:-$(jq -r '.version // empty' <<<"$MAN_JSON")}"
    [[ -n "$ID" && -n "$VERSION" ]] || { echo "ERROR: could not discover id/version from manifest" >&2; exit 1; }
    echo "   → Discovered UID: mcp_server:${ID}@${VERSION}"
  fi

  # Resolve the index URL next to the manifest
  INDEX_BASE="${MANIFEST_URL%/matrix/*}/matrix"
  INDEX_URL="${INDEX_BASE}/index.json"

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
