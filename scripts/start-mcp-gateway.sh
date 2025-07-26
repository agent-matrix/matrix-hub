#!/usr/bin/env bash
# 2-Start-MCP-Gateway.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/../mcpgateway"
VENV_ACTIVATE="${PROJECT_DIR}/.venv/bin/activate"
ENV_FILE_ROOT="${SCRIPT_DIR}/../.env"
ENV_FILE_PROJECT="${PROJECT_DIR}/.env"
LOG_DIR="${PROJECT_DIR}/logs"
LOG_FILE="${LOG_DIR}/mcpgateway.log"

# 1) venv
[ -f "${VENV_ACTIVATE}" ] || { echo "❌ venv not found at ${VENV_ACTIVATE}" >&2; exit 1; }
# shellcheck disable=SC1090
source "${VENV_ACTIVATE}"

# 2) env
if [ -f "${ENV_FILE_ROOT}" ]; then
  ENV_FILE="${ENV_FILE_ROOT}"
elif [ -f "${ENV_FILE_PROJECT}" ]; then
  ENV_FILE="${ENV_FILE_PROJECT}"
else
  echo "❌ No .env found in ${SCRIPT_DIR}/.. or ${PROJECT_DIR}." >&2
  exit 1
fi
# shellcheck disable=SC2046
export $(grep -v '^\s*#' "${ENV_FILE}" | xargs)
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-4444}"

mkdir -p "${LOG_DIR}"

# 3) Port check
if ss -tunlp 2>/dev/null | grep -q ":${PORT}"; then
  read -r -p "⚠️  Port ${PORT} is in use. Stop existing process and continue? [y/N] " confirm
  if [[ "${confirm,,}" == "y" ]]; then
    pkill -f "mcpgateway --host .* --port ${PORT}" || true
    sleep 1
  else
    echo "Aborting."
    exit 1
  fi
fi

# 4) Init DB
echo "⏳ Initializing DB…"
python -m mcpgateway.db
echo "✅ DB ready."

# 5) Start
echo "▶ Starting MCP Gateway on ${HOST}:${PORT} (logs: ${LOG_FILE})"
cd "${PROJECT_DIR}"
nohup mcpgateway --host "${HOST}" --port "${PORT}" \
  > "${LOG_FILE}" 2>&1 < /dev/null &
PID=$!
echo "${PID}" > "${PROJECT_DIR}/mcpgateway.pid"
echo "✅ Started (PID: ${PID})"

# 6) Wait for health
for i in {1..60}; do
  if curl -fsS "http://${HOST}:${PORT}/health" | jq -e '.status=="ok"' >/dev/null 2>&1; then
    echo "✅ Healthy: http://${HOST}:${PORT}/health"
    exit 0
  fi
  sleep 2
done
echo "⚠️  Gateway not healthy; showing last log lines:"
tail -n 80 "${LOG_FILE}" || true
exit 1
