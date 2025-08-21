#!/usr/bin/env bash
#
# mock_ingest_with_token.sh
#
# Mints a temporary admin token and sends a mock ingest request to the Hub.
#

set -euo pipefail

# --- Configuration & Paths ---
HUB_URL="${HUB_URL:-http://127.0.0.1:443}"
REMOTE_URL="https://raw.githubusercontent.com/ruslanmv/hello-mcp/refs/heads/main/matrix/index.json"

# Discover paths relative to the script's location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "${SCRIPT_DIR}")"
PROJECT_DIR="${BASE_DIR}/mcpgateway"
VENV_DIR="${PROJECT_DIR}/.venv"
ENV_FILE="${PROJECT_DIR}/.env"

# --- Helper Functions ---
log() { printf "\n[$(date +'%T')] %s\n" "$*"; }
die() { printf "\nERROR: %s\n" "$*" >&2; exit 1; }

# --- Script Execution ---

# 1. Activate Virtual Environment
if [ ! -f "${VENV_DIR}/bin/activate" ]; then
    die "Virtual environment not found at ${VENV_DIR}/bin/activate. Run the main setup script first."
fi
# shellcheck disable=SC1090
source "${VENV_DIR}/bin/activate"
log "✅ Virtual environment activated."

# 2. Load Environment Variables from .env
if [ ! -f "${ENV_FILE}" ]; then
    die ".env file not found at ${ENV_FILE}. Run the main setup script first."
fi
set -o allexport
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +o allexport
log "✅ Environment variables loaded."

# 3. Mint an Admin JWT on the fly
log "⏳ Minting temporary admin JWT..."
auth_user="${BASIC_AUTH_USERNAME:-admin}"
jwt_secret="${JWT_SECRET_KEY:-my-test-key}"

ADMIN_TOKEN=$(
  python3 -m mcpgateway.utils.create_jwt_token \
    --username "$auth_user" \
    --secret   "$jwt_secret" \
    --exp 120 # Token is valid for 120 seconds
)
if [ -z "$ADMIN_TOKEN" ]; then
    die "Failed to mint JWT. Check credentials and JWT_SECRET_KEY in the .env file."
fi
log "✅ Token minted successfully."

# 4. Send the mock ingest request with the new token
log "▶️ Sending a mock ingest request to ${HUB_URL}/ingest..."
AUTH_HEADER=(-H "Authorization: Bearer ${ADMIN_TOKEN}")

curl -sS -X POST "${HUB_URL}/ingest" \
  "${AUTH_HEADER[@]}" \
  -H "Content-Type: application/json" \
  -d "{\"url\":\"$REMOTE_URL\"}" | jq .

log "✅ Done."
