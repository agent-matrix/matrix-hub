#!/usr/bin/env bash
#
# verify-servers.sh
#
# Verifies that the MCP Gateway is running by minting an admin token
# and querying the /servers endpoint. It must be run after the main
# run.sh script has successfully started the gateway.

set -euo pipefail

# --- Configuration & Paths ---
# Use the same robust path discovery as the main run.sh script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "${SCRIPT_DIR}")"
PROJECT_DIR="${BASE_DIR}/mcpgateway"
VENV_DIR="${PROJECT_DIR}/.venv"
ENV_FILE="${PROJECT_DIR}/.env"

# --- Helper Functions ---
log() { printf "\n[$(date +'%T')] %s\n" "$*"; }
die() { printf "\nERROR: %s\n" "$*" >&2; exit 1; }

# --- Script Execution ---
log "### Verifying MCP Gateway Servers ###"

# 1. Activate Virtual Environment
if [ ! -f "${VENV_DIR}/bin/activate" ]; then
    die "Virtual environment not found at ${VENV_DIR}/bin/activate. Please run the main setup script first."
fi
# shellcheck disable=SC1090
source "${VENV_DIR}/bin/activate"
log "✅ Virtual environment activated."

# 2. Load Environment Variables from the correct .env file
if [ ! -f "${ENV_FILE}" ]; then
    die ".env file not found at ${ENV_FILE}. Please run the main setup script first."
fi
set -o allexport
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +o allexport
log "✅ Environment variables loaded from ${ENV_FILE}."

# 3. Mint an Admin JWT
local_host="127.0.0.1" # Use 127.0.0.1 for client connections, not 0.0.0.0
local_port="${PORT:-4444}"
auth_user="${BASIC_AUTH_USERNAME:-admin}"
jwt_secret="${JWT_SECRET_KEY:-my-test-key}" # Provide a sane default

log "⏳ Minting admin JWT for user '${auth_user}'..."
ADMIN_TOKEN=$(
  python3 -m mcpgateway.utils.create_jwt_token \
    --username "$auth_user" \
    --secret   "$jwt_secret" \
    --exp 120
)
if [ -z "$ADMIN_TOKEN" ]; then
    die "Failed to mint JWT. Check your credentials and JWT_SECRET_KEY in the .env file."
fi
log "✅ Token minted successfully."

# 4. Query the /servers endpoint
log "⏳ Querying active servers from http://${local_host}:${local_port}/servers..."
if ! curl -sS -H "Authorization: Bearer $ADMIN_TOKEN" "http://${local_host}:${local_port}/servers" | jq .; then
    die "Failed to query the /servers endpoint. Is the gateway running? Check its logs."
fi