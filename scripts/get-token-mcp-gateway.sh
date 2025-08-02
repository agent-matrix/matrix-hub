#!/usr/bin/env bash
#
# get-token-mcp-gateway.sh
#
# Mints an admin JWT and prepares environment variables for the shell.
# It prints `export` commands to stdout, intended to be used with `eval`:
# eval "$(make gateway-token)"

set -euo pipefail

# --- Configuration & Paths ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Correctly locate BASE_DIR relative to the script's location
BASE_DIR="$(dirname "${SCRIPT_DIR}")"
# Use PROJECT_DIR passed from Makefile, or default to a sibling directory
PROJECT_DIR="${PROJECT_DIR:-${BASE_DIR}/mcpgateway}"
VENV_DIR="${PROJECT_DIR}/.venv"
# The .env file should be in the main project root, not the gateway subdir
ENV_FILE="${BASE_DIR}/.env"

# --- Helper Functions ---
# Log messages to stderr to avoid interfering with stdout capture
log() { printf "[$(date +'%T')] %s\n" "$*" >&2; }
die() { printf "\nERROR: %s\n" "$*" >&2; exit 1; }

# --- Script Execution ---
log "### Generating MCP Gateway Admin Token & Hub Endpoint ###"

# 1. Activate Virtual Environment
if [ ! -f "${VENV_DIR}/bin/activate" ]; then
    die "Virtual environment not found at ${VENV_DIR}/bin/activate. Run setup first."
fi
# shellcheck disable=SC1090
source "${VENV_DIR}/bin/activate"

# 2. Load Environment Variables from the .env file
if [ ! -f "${ENV_FILE}" ]; then
    die ".env file not found at ${ENV_FILE}. Run setup first."
fi
set -o allexport
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +o allexport

# 3. Define variables with defaults from the loaded .env file
auth_user="${BASIC_AUTH_USERNAME:-admin}"
jwt_secret="${JWT_SECRET_KEY:-my-test-key}"
hub_host="${HOST:-0.0.0.0}" # Get HOST from .env, or use default
hub_port="${PORT:-7300}"     # Get PORT from .env, or use default

# 4. Mint an Admin JWT using loaded credentials
log "⏳ Minting admin JWT for user '${auth_user}'..."
ADMIN_TOKEN=$(
  python3 -m mcpgateway.utils.create_jwt_token \
    --username "$auth_user" \
    --secret   "$jwt_secret" \
    --exp 120
)
if [ -z "$ADMIN_TOKEN" ]; then
    die "Failed to mint JWT. Check credentials in ${ENV_FILE}."
fi

log "✅ Token and endpoint prepared. Use 'eval' to export them."

# 5. Output the export commands to standard output
# This allows the parent shell to capture and execute them via `eval`.
# Using a heredoc (cat <<EOF) is a clean way to print multiple lines.
cat <<EOF
export ADMIN_TOKEN='${ADMIN_TOKEN}'
export HUB_ENDPOINT='${hub_host}:${hub_port}'
EOF