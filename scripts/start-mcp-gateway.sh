#!/usr/bin/env bash
# Robust starter for MCP Gateway with idempotent DB init and safe auto-stamping.
# - Detects pre-existing columns (e.g., gateways.slug) in SQLite and stamps Alembic to head
#   using the Alembic Python API (no reliance on alembic.ini).
# - Leaves data intact; avoids duplicate-column errors during bootstrap.
# - Non-interactive friendly; configurable via env variables below.

set -euo pipefail

# =============================================================================
# Configuration (override via env)
# =============================================================================
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-4444}"
BASIC_AUTH_USERNAME="${BASIC_AUTH_USERNAME:-admin}"

# Control DB stamping behavior:
GATEWAY_DB_FORCE_STAMP="${GATEWAY_DB_FORCE_STAMP:-0}"   # 1 = always stamp head before init
GATEWAY_DB_AUTO_RETRY="${GATEWAY_DB_AUTO_RETRY:-1}"     # 1 = retry init once after stamping if init fails

# When port is busy: 0 = abort (default), 1 = kill the process using the port and continue
GATEWAY_KILL_PORT="${GATEWAY_KILL_PORT:-0}"

# =============================================================================
# Paths
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_DIR="${PROJECT_ROOT}/mcpgateway"
VENV_ACTIVATE="${PROJECT_DIR}/.venv/bin/activate"
DB_FILE="${PROJECT_DIR}/mcp.db"
ALEMBIC_DIR="${PROJECT_DIR}/mcpgateway/alembic"   # migrations live here
ENV_SOURCE_LOCAL="${PROJECT_ROOT}/.env.gateway.local"
ENV_SOURCE_EXAMPLE="${PROJECT_ROOT}/.env.gateway.example"
ENV_DESTINATION="${PROJECT_DIR}/.env"
LOG_DIR="${PROJECT_DIR}/logs"
LOG_FILE="${LOG_DIR}/mcpgateway.log"
PID_FILE="${PROJECT_DIR}/mcpgateway.pid"

# =============================================================================
# Helpers
# =============================================================================
log()  { printf "▶ %s\n" "$*"; }
info() { printf "ℹ️  %s\n" "$*"; }
ok()   { printf "✅ %s\n" "$*"; }
warn() { printf "⚠️  %s\n" "$*" >&2; }
err()  { printf "❌ %s\n" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

sqlite_has_table() {
  local db="$1" table="$2"
  [[ -f "$db" ]] || return 1
  have sqlite3 || return 1
  sqlite3 "$db" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='$table' LIMIT 1;" | grep -q 1
}

sqlite_has_column() {
  local db="$1" table="$2" col="$3"
  [[ -f "$db" ]] || return 1
  have sqlite3 || return 1
  sqlite3 "$db" "SELECT 1 FROM pragma_table_info('$table') WHERE name='$col' LIMIT 1;" | grep -q 1
}

# Run Alembic "stamp head" using Python API with explicit script_location & DB URL.
alembic_stamp_head() {
  (
    cd "$PROJECT_DIR" || exit 1
    python - "$PROJECT_DIR" "$ALEMBIC_DIR" "$DB_FILE" <<'PY'
import os, sys
from alembic.config import Config
from alembic import command

project_dir, alembic_dir, db_path = sys.argv[1], sys.argv[2], sys.argv[3]

cfg = Config()  # programmatic config, no alembic.ini required
cfg.set_main_option("script_location", alembic_dir)
cfg.set_main_option("sqlalchemy.url", f"sqlite:///{db_path}")
# Some env.py variants look for these:
cfg.set_main_option("timezone", "utc")
cfg.set_main_option("prepend_sys_path", "true")

command.stamp(cfg, "head")
print(f"[alembic] Stamped head (script_location={alembic_dir})")
PY
  )
}

# =============================================================================
# 1) Activate venv
# =============================================================================
[[ -f "${VENV_ACTIVATE}" ]] || err "virtualenv not found at ${VENV_ACTIVATE}"
# shellcheck disable=SC1090
source "${VENV_ACTIVATE}"
ok "Activated Python environment from ${VENV_ACTIVATE}"

# =============================================================================
# 2) Prepare .env for the gateway app
# =============================================================================
if [[ ! -f "${ENV_SOURCE_LOCAL}" ]]; then
  info "No .env.gateway.local found in project root."
  if [[ -f "${ENV_SOURCE_EXAMPLE}" ]]; then
    info "Copying from ${ENV_SOURCE_EXAMPLE} to create your local config..."
    cp "${ENV_SOURCE_EXAMPLE}" "${ENV_SOURCE_LOCAL}"
    warn "Created ${ENV_SOURCE_LOCAL} using example defaults. Update credentials as needed."
  else
    err "No .env.gateway.local or .env.gateway.example found in project root. Cannot continue."
  fi
fi

ok "Found user config at ${ENV_SOURCE_LOCAL}."
info "Copying to ${ENV_DESTINATION} for the application to use."
cp "${ENV_SOURCE_LOCAL}" "${ENV_DESTINATION}"

set -o allexport
# shellcheck disable=SC1090
source "${ENV_DESTINATION}"
set +o allexport
ok "Loaded environment variables."

# =============================================================================
# 3) Port check
# =============================================================================
if have lsof && lsof -iTCP:"${PORT}" -sTCP:LISTEN -t >/dev/null 2>&1; then
  if [[ "${GATEWAY_KILL_PORT}" == "1" ]]; then
    warn "Port ${PORT} is in use. Attempting to stop existing process..."
    lsof -iTCP:"${PORT}" -sTCP:LISTEN -t | xargs kill -9 || true
    sleep 1
  else
    err "Port ${PORT} is already in use. Set GATEWAY_KILL_PORT=1 to auto-kill or choose a different PORT."
  fi
fi

# =============================================================================
# 4) cd into project dir for module resolution
# =============================================================================
cd "${PROJECT_DIR}"

# =============================================================================
# 5) Preflight schema guard / stamping
# =============================================================================
do_stamp=0
if [[ "${GATEWAY_DB_FORCE_STAMP}" == "1" ]]; then
  info "GATEWAY_DB_FORCE_STAMP=1 → will stamp Alembic head before init."
  do_stamp=1
elif [[ -f "${DB_FILE}" ]] && have sqlite3; then
  if sqlite_has_table "${DB_FILE}" "gateways" && sqlite_has_column "${DB_FILE}" "gateways" "slug"; then
    info "Detected existing 'gateways.slug' in ${DB_FILE}; stamping Alembic head to avoid duplicate-column migration."
    do_stamp=1
  fi
fi

if [[ "${do_stamp}" == "1" ]]; then
  if alembic_stamp_head; then
    ok "Alembic stamped to head successfully."
  else
    warn "Alembic stamp head failed; continuing. Migrations may still run and could error."
  fi
fi

# =============================================================================
# 6) Initialize DB (create/migrate). Retry once after stamping on failure.
# =============================================================================
echo "⏳ Initializing database (creating/migrating tables)..."
init_ok=0
if python -m mcpgateway.db; then
  init_ok=1
else
  warn "Database initialization failed."
  if [[ "${GATEWAY_DB_AUTO_RETRY}" == "1" ]]; then
    info "Attempting one-time Alembic stamp to head, then retrying init..."
    alembic_stamp_head || warn "Stamp failed during retry; proceeding to retry init anyway."
    if python -m mcpgateway.db; then
      init_ok=1
    fi
  fi
fi

[[ "${init_ok}" == "1" ]] || err "Database initialization failed. Inspect ${DB_FILE} and Alembic state."

ok "Database initialized successfully."

# =============================================================================
# 7) Start gateway in background, log to file
# =============================================================================
mkdir -p "${LOG_DIR}"
echo "🎯 Starting MCP Gateway on ${HOST}:${PORT} with user '${BASIC_AUTH_USERNAME}'..."

if have mcpgateway; then
  nohup mcpgateway --host "${HOST}" --port "${PORT}" > "${LOG_FILE}" 2>&1 &
else
  # Fallback to module entrypoint if console script is unavailable
  nohup python -m mcpgateway.app --host "${HOST}" --port "${PORT}" > "${LOG_FILE}" 2>&1 &
fi

PID=$!
echo "${PID}" > "${PID_FILE}"
ok "MCP Gateway started (PID: ${PID}). Logs → ${LOG_FILE}"

# =============================================================================
# 8) Wait for health
# =============================================================================
echo "⏳ Waiting for gateway to become healthy..."
HEALTH_URL="http://127.0.0.1:${PORT}/health"
for i in {1..30}; do  # ~60 seconds total
  if have curl && curl -fsS "${HEALTH_URL}" >/dev/null 2>&1; then
    ADMIN_URL="http://localhost:${PORT}/admin/"
    ok "Gateway is healthy and running at http://${HOST}:${PORT}"
    echo "➡️  Admin UI: ${ADMIN_URL}"
    exit 0
  fi
  sleep 2
done

err "Gateway did not become healthy in time. Check logs: tail -f ${LOG_FILE}"
