#!/usr/bin/env bash

set -euo pipefail

# -----------------------------------------------------------------------------
# Determine script & project paths
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_DIR="${PROJECT_ROOT}/mcpgateway"
VENV_ACTIVATE="${PROJECT_DIR}/.venv/bin/activate"

# -----------------------------------------------------------------------------
# 1) Activate Python venv immediately
# -----------------------------------------------------------------------------
if [ ! -f "${VENV_ACTIVATE}" ]; then
  echo "❌ virtualenv not found at ${VENV_ACTIVATE}" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "${VENV_ACTIVATE}"
echo "✅ Activated Python environment from ${VENV_ACTIVATE}"

# -----------------------------------------------------------------------------
# 2) Handle .env file logic
# -----------------------------------------------------------------------------
ENV_SOURCE_LOCAL="${PROJECT_ROOT}/.env.gateway.local"
ENV_SOURCE_EXAMPLE="${PROJECT_ROOT}/.env.gateway.example"
ENV_DESTINATION="${PROJECT_DIR}/.env"

# Check for the local .env file first
if [ ! -f "${ENV_SOURCE_LOCAL}" ]; then
    echo "ℹ️ No .env.gateway.local found in project root."
    # If not found, try to create it from the example file
    if [ -f "${ENV_SOURCE_EXAMPLE}" ]; then
        echo "ℹ️ Copying from ${ENV_SOURCE_EXAMPLE} to create your local config..."
        cp "${ENV_SOURCE_EXAMPLE}" "${ENV_SOURCE_LOCAL}"
        echo "⚠️ WARNING: Created ${ENV_SOURCE_LOCAL} using default example values. The gateway will continue starting, but you should edit this file with your actual credentials later."
    else
        echo "❌ No .env.gateway.local or .env.gateway.example found in project root. Cannot continue." >&2
        exit 1
    fi
fi

# At this point, .env.gateway.local exists. Now, copy it to where the app expects it.
echo "✅ Found user config at ${ENV_SOURCE_LOCAL}."
echo "ℹ️ Copying to ${ENV_DESTINATION} for the application to use."
cp "${ENV_SOURCE_LOCAL}" "${ENV_DESTINATION}"

# Load the environment variables for this script's session
set -o allexport
# shellcheck disable=SC1090
source "${ENV_DESTINATION}"
set +o allexport
echo "✅ Loaded environment variables."

# -----------------------------------------------------------------------------
# 3) Check port availability (using lsof for better macOS/Linux compatibility)
# -----------------------------------------------------------------------------
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-4444}"
if lsof -iTCP:"${PORT}" -sTCP:LISTEN -t >/dev/null; then
  echo "⚠️ Port ${PORT} is already in use."
  read -r -p "Stop the existing process on port ${PORT} and continue? [y/N] " confirm
  if [[ "${confirm,,}" == "y" ]]; then
    echo "Stopping existing process..."
    lsof -iTCP:"${PORT}" -sTCP:LISTEN -t | xargs kill -9
    sleep 1
  else
    echo "Aborting startup."
    exit 1
  fi
fi

# -----------------------------------------------------------------------------
# 4) Change into project dir so Python can find the mcpgateway module
# -----------------------------------------------------------------------------
cd "${PROJECT_DIR}"

# -----------------------------------------------------------------------------
# 5) Initialize the database with error checking
# -----------------------------------------------------------------------------
echo "⏳ Initializing database (creating/migrating tables)..."
if ! python -m mcpgateway.db; then
    echo "❌ Database initialization failed. Please check the error above." >&2
    exit 1
fi
echo "✅ Database initialized successfully."

# -----------------------------------------------------------------------------
# 6) Start the MCP Gateway in the background
# -----------------------------------------------------------------------------
LOG_DIR="${PROJECT_DIR}/logs"
LOG_FILE="${LOG_DIR}/mcpgateway.log"
mkdir -p "${LOG_DIR}"

BASIC_AUTH_USERNAME="${BASIC_AUTH_USERNAME:-admin}"

echo "🎯 Starting MCP Gateway on ${HOST}:${PORT} with user '${BASIC_AUTH_USERNAME}'..."
nohup mcpgateway --host "${HOST}" --port "${PORT}" > "${LOG_FILE}" 2>&1 &
PID=$!
echo "${PID}" > "${PROJECT_DIR}/mcpgateway.pid"
echo "✅ MCP Gateway started (PID: ${PID}). Logs are being written to ${LOG_FILE}"

# -----------------------------------------------------------------------------
# 7) Wait for the service to become healthy (using 127.0.0.1 for reliability)
# -----------------------------------------------------------------------------
echo "⏳ Waiting for gateway to become healthy..."
HEALTH_URL="http://127.0.0.1:${PORT}/health"
for i in {1..30}; do # 60 seconds timeout
  if curl -fsS "${HEALTH_URL}" >/dev/null 2>&1; then
    ADMIN_URL="http://localhost:${PORT}/admin/"
    echo "✅ Gateway is healthy and running at http://${HOST}:${PORT}"
    echo "➡️ You can now access the Admin UI at: ${ADMIN_URL}"
    exit 0
  fi
  sleep 2
done

echo "❌ Gateway did not become healthy in time. Please check the logs:"
echo "   tail -f ${LOG_FILE}"
exit 1