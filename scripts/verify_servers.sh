#!/usr/bin/env bash
# 4-verify_servers.sh
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-./mcpgateway}"
VENV_ACTIVATE="${PROJECT_DIR}/.venv/bin/activate"
ENV_FILE="${PROJECT_DIR}/.env"

[ -f "${VENV_ACTIVATE}" ] || { echo "❌ venv not found at ${VENV_ACTIVATE}" >&2; exit 1; }
# shellcheck disable=SC1090
source "${VENV_ACTIVATE}"

[ -f "${ENV_FILE}" ] || { echo "❌ ${ENV_FILE} not found." >&2; exit 1; }
# shellcheck disable=SC2046
export $(grep -v '^\s*#' "${ENV_FILE}" | xargs)

HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-4444}"

# Backwards-compatible env names
BASIC_AUTH_USER="${BASIC_AUTH_USER:-${BASIC_AUTH_USERNAME:-admin}}"
BASIC_AUTH_PASSWORD="${BASIC_AUTH_PASSWORD:-${BASIC_AUTH_PASSWORD:-changeme}}"
JWT_SECRET_KEY="${JWT_SECRET_KEY:-dev-secret}"

echo "⏳ Minting admin JWT…"
ADMIN_TOKEN=$(
  JWT_SECRET_KEY="$JWT_SECRET_KEY" \
    python3 -m mcpgateway.utils.create_jwt_token \
      --username "$BASIC_AUTH_USER" \
      --secret   "$JWT_SECRET_KEY" \
      --exp 120
)
echo "✅ Token minted."

echo "⏳ Querying /servers …"
curl -sS -H "Authorization: Bearer $ADMIN_TOKEN" "http://${HOST}:${PORT}/servers" | jq .
