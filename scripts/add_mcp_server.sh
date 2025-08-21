#!/usr/bin/env bash
# =============================================================================
# Add an MCP server to matrix/index.json and (optionally) push it to a running Hub.
#
# Usage:
#   examples/add_mcp_server.sh \
#     [--id <id>] [--version <ver>] [--name "<Name>"] [--summary "<text>"] \
#     [--manifest-url "<URL>"] [--register]
# =============================================================================

set -Eeuo pipefail

say()  { printf "\033[36m%s\033[0m\n" "$*"; }
ok()   { printf "\033[32m✔ %s\033[0m\n" "$*"; }
warn() { printf "\033[33m⚠ %s\033[0m\n" "$*"; }
err()  { printf "\033[31m✖ %s\033[0m\n" "$*"; exit 1; }

# -------------------------------------------------------------------------
# 0) Auto-locate project root (so you can run this from anywhere)
# -------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"
ok "Working in project root: $PROJECT_ROOT"

# -------- defaults / args ----------
DEFAULT_MANIFEST_URL="https://raw.githubusercontent.com/ruslanmv/hello-mcp/refs/heads/main/matrix/hello-server.manifest.json"

ID=""
VERSION=""
NAME=""
SUMMARY=""
MANIFEST_URL=""
REGISTER=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --id)           ID="$2";           shift 2 ;;
    --version)      VERSION="$2";      shift 2 ;;
    --name)         NAME="$2";         shift 2 ;;
    --summary)      SUMMARY="$2";      shift 2 ;;
    --manifest-url) MANIFEST_URL="$2"; shift 2 ;;
    --register)     REGISTER=1;        shift   ;;
    -h|--help)
      sed -n '1,50p' "$0"; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

# -------- fallback manifest if none provided ----------
if [[ -z "$MANIFEST_URL" ]]; then
  MANIFEST_URL="$DEFAULT_MANIFEST_URL"
  say "ℹ️  No --manifest-url provided; using default:"
  say "   $MANIFEST_URL"
fi

# -------- auto-discover ID/VERSION if missing ----------
if [[ -z "$ID" || -z "$VERSION" ]]; then
  command -v jq >/dev/null 2>&1 || err "jq is required to auto-discover id/version from the manifest."
  say "ℹ️  Fetching manifest to discover id/version…"
  MAN_JSON="$(curl -fsSL "$MANIFEST_URL")" || err "Failed to fetch manifest."
  [[ -z "$ID" ]]      && ID=$(echo "$MAN_JSON" | jq -r '.id // empty')
  [[ -z "$VERSION" ]] && VERSION=$(echo "$MAN_JSON" | jq -r '.version // empty')
  [[ -n "$ID" && -n "$VERSION" ]] \
    || err "Could not discover id and version from the manifest."
  ok "Discovered: ID=$ID, VERSION=$VERSION"
fi

# -------- sanity checks ----------
if [[ ! -f "Makefile" || ! -f "scripts/init.py" ]]; then
  err "Makefile and scripts/init.py not found in $PROJECT_ROOT. Are you in the correct repo?"
fi

# -------- 1) Ensure empty index exists ----------
say "▶ Ensuring matrix/index.json exists…"
make -s index-init

# -------- 2) Append/update entity in index ----------
say "▶ Adding/updating ${ID}@${VERSION} in matrix/index.json…"
python3 scripts/init.py add-url \
  --out matrix/index.json \
  --manifest-url "$MANIFEST_URL"
ok "Index updated → matrix/index.json"

# -------- 3) Optional: register in a running Hub ----------
if [[ "$REGISTER" -eq 1 ]]; then
  : "${HUB_URL:?Set HUB_URL (e.g., http://127.0.0.1:443)}"
  : "${ADMIN_TOKEN:?Set ADMIN_TOKEN to your Hub’s API_TOKEN}"

  REMOTES_URL="${HUB_URL%/}/remotes"
  INGEST_URL="${HUB_URL%/}/ingest"
  INSTALL_URL="${HUB_URL%/}/catalog/install"

  say "▶ Registering with Hub (remote → ingest → install) …"
  say "   • POST ${REMOTES_URL}"
  curl -fsS -X POST "$REMOTES_URL" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"url\":\"${MANIFEST_URL%/matrix/*}/matrix/index.json\"}" \
    | jq -r '.' || true

  say "   • POST ${INGEST_URL}"
  curl -fsS -X POST "$INGEST_URL" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"url\":\"${MANIFEST_URL%/matrix/*}/matrix/index.json\"}" \
    | jq -r '.' || true

  say "   • POST ${INSTALL_URL}"
  UID="mcp_server:${ID}@${VERSION}"
  curl -fsS -X POST "$INSTALL_URL" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"id\":\"${UID}\",\"target\":\"./\"}" \
    | jq -r '.' || true

  ok "Done — remote, ingest & install triggered in your Hub."
fi
