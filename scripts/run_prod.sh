#!/usr/bin/env bash
# scripts/run_prod.sh
# Start MCP‑Gateway (mcpgateway/.venv) and Matrix Hub (./.venv) for production.
# Both processes are supervised; if one exits, the other is stopped gracefully.

set -Eeuo pipefail

# ---------------------------
# Paths & defaults
# ---------------------------
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

# --- Gateway paths & defaults ---
GATEWAY_DIR="${GATEWAY_DIR:-${ROOT_DIR}/mcpgateway}"
GATEWAY_ENV_LOCAL="${GATEWAY_ENV_LOCAL:-${ROOT_DIR}/.env.gateway.local}"
GATEWAY_ENV_FILE="${GATEWAY_ENV_FILE:-${GATEWAY_DIR}/.env}"
GATEWAY_VENV="${GATEWAY_DIR}/.venv"
GATEWAY_GUNICORN="${GATEWAY_VENV}/bin/gunicorn"
GATEWAY_UVICORN="${GATEWAY_VENV}/bin/uvicorn"
GATEWAY_PYTHON="${GATEWAY_VENV}/bin/python"
GATEWAY_HOST_DEFAULT="0.0.0.0"
GATEWAY_PORT_DEFAULT="4444"
# Override if your gateway app module uses a different import path:
GW_APP_MODULE="${GW_APP_MODULE:-mcp_gateway.app:app}"

# Production tuning (override via env as needed)
GW_WORKERS="${GW_WORKERS:-}"                  # auto-calc if empty
GW_TIMEOUT="${GW_TIMEOUT:-60}"
GW_GRACEFUL_TIMEOUT="${GW_GRACEFUL_TIMEOUT:-30}"
GW_KEEPALIVE="${GW_KEEPALIVE:-5}"
GW_MAX_REQUESTS="${GW_MAX_REQUESTS:-1000}"
GW_MAX_REQUESTS_JITTER="${GW_MAX_REQUESTS_JITTER:-100}"
GW_LOG_LEVEL="${GW_LOG_LEVEL:-info}"
GW_ACCESS_LOGFILE="${GW_ACCESS_LOGFILE:--}"   # stdout
GW_ERROR_LOGFILE="${GW_ERROR_LOGFILE:--}"     # stderr
GW_PRELOAD="${GW_PRELOAD:-false}"             # "true" to enable --preload

# --- Hub paths & defaults ---
HUB_ENV_FILE="${HUB_ENV_FILE:-${ROOT_DIR}/.env}"
HUB_ENV_EXAMPLE="${HUB_ENV_EXAMPLE:-${ROOT_DIR}/.env.example}"
HUB_VENV="${ROOT_DIR}/.venv"
HUB_GUNICORN="${HUB_VENV}/bin/gunicorn"
HUB_UVICORN="${HUB_VENV}/bin/uvicorn"
HUB_PYTHON="${HUB_VENV}/bin/python"
HUB_HOST_DEFAULT="0.0.0.0"
HUB_PORT_DEFAULT="443"
HUB_APP_MODULE="${APP_MODULE:-src.app:app}"

# Production tuning (override via env as needed)
HUB_WORKERS="${HUB_WORKERS:-}"                # auto-calc if empty
HUB_TIMEOUT="${HUB_TIMEOUT:-60}"
HUB_GRACEFUL_TIMEOUT="${HUB_GRACEFUL_TIMEOUT:-30}"
HUB_KEEPALIVE="${HUB_KEEPALIVE:-5}"
HUB_MAX_REQUESTS="${HUB_MAX_REQUESTS:-1000}"
HUB_MAX_REQUESTS_JITTER="${HUB_MAX_REQUESTS_JITTER:-100}"
HUB_LOG_LEVEL="${HUB_LOG_LEVEL:-info}"
HUB_ACCESS_LOGFILE="${HUB_ACCESS_LOGFILE:--}"
HUB_ERROR_LOGFILE="${HUB_ERROR_LOGFILE:--}"
HUB_PRELOAD="${HUB_PRELOAD:-false}"

# Flags
GATEWAY_SKIP_START="${GATEWAY_SKIP_START:-0}"

# ---------------------------
# Helpers
# ---------------------------
log()  { printf "▶ %s\n" "$*"; }
warn() { printf "⚠ %s\n" "$*" >&2; }
err()  { printf "✖ %s\n" "$*" >&2; exit 1; }

has_cmd() { command -v "$1" >/dev/null 2>&1; }

port_listening() {
  local port="$1"
  if has_cmd lsof; then
    lsof -nP -i :"${port}" | grep LISTEN >/dev/null 2>&1
  elif has_cmd netstat; then
    netstat -an 2>/dev/null | grep -E "[:\.]${port}[^0-9]" | grep LISTEN >/dev/null 2>&1
  else
    (echo >/dev/tcp/127.0.0.1/"${port}") >/dev/null 2>&1
  fi
}

wait_for_port() {
  local port="$1" timeout="${2:-25}" waited=0
  while ! port_listening "${port}"; do
    sleep 1
    waited=$((waited+1))
    if [ "${waited}" -ge "${timeout}" ]; then
      return 1
    fi
  done
  return 0
}

get_nprocs() {
  local n
  n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  if [ -z "${n}" ]; then
    n="$(sysctl -n hw.ncpu 2>/dev/null || true)"
  fi
  if [ -z "${n}" ]; then
    n="2"
  fi
  printf "%s" "${n}"
}

calc_workers() {
  local override="$1"
  if [ -n "${override}" ]; then
    printf "%s" "${override}"
    return 0
  fi
  local nprocs
  nprocs="$(get_nprocs)"
  printf "%s" "$(( 2 * nprocs + 1 ))"
}

# ---------------------------
# Determine gateway port from its env (if present)
# ---------------------------
GW_PORT="${GATEWAY_PORT_DEFAULT}"
if [ -f "${GATEWAY_ENV_FILE}" ]; then
  # shellcheck disable=SC1090
  GW_PORT="$( ( set -a; . "${GATEWAY_ENV_FILE}"; set +a; printf "%s" "${PORT:-${GATEWAY_PORT_DEFAULT}}" ) )"
elif [ -f "${GATEWAY_ENV_LOCAL}" ]; then
  GW_PORT="$( ( set -a; . "${GATEWAY_ENV_LOCAL}"; set +a; printf "%s" "${PORT:-${GATEWAY_PORT_DEFAULT}}" ) )"
fi

# ---------------------------
# Prepare Hub .env (copy example if missing)
# ---------------------------
if [ ! -f "${HUB_ENV_FILE}" ] && [ -f "${HUB_ENV_EXAMPLE}" ]; then
  cp "${HUB_ENV_EXAMPLE}" "${HUB_ENV_FILE}"
  log "Created ${HUB_ENV_FILE} from ${HUB_ENV_EXAMPLE}"
fi

# ---------------------------
# Start MCP‑Gateway (background, subshell)
# ---------------------------
GW_PID=""
start_gateway() {
  if [ "${GATEWAY_SKIP_START}" = "1" ]; then
    log "Skipping MCP‑Gateway start (GATEWAY_SKIP_START=1)."
    return 0
  fi

  if port_listening "${GW_PORT}"; then
    log "MCP‑Gateway already listening on port ${GW_PORT}; will not start another instance."
    return 0
  fi

  [ -d "${GATEWAY_DIR}" ] || err "Gateway project not found at ${GATEWAY_DIR}. Run setup (scripts/setup-mcp-gateway.sh) first."
  [ -f "${GATEWAY_VENV}/bin/activate" ] || err "Gateway venv missing at ${GATEWAY_VENV}. Run gateway setup first."

  # Ensure gateway .env exists
  if [ ! -f "${GATEWAY_ENV_FILE}" ] && [ -f "${GATEWAY_ENV_LOCAL}" ]; then
    cp "${GATEWAY_ENV_LOCAL}" "${GATEWAY_ENV_FILE}"
    log "Created ${GATEWAY_ENV_FILE} from ${GATEWAY_ENV_LOCAL}"
  fi

  (
    cd "${GATEWAY_DIR}"

    # Load gateway env if present (limited to this subshell)
    if [ -f ".env" ]; then
      # shellcheck disable=SC1091
      set -a; . ".env"; set +a
    fi

    # Resolve host/port defaults *within* gateway env context
    local GW_HOST_LOCAL="${HOST:-${GATEWAY_HOST_DEFAULT}}"
    local GW_PORT_LOCAL="${PORT:-${GATEWAY_PORT_DEFAULT}}"

    # Activate gateway venv
    # shellcheck disable=SC1091
    . "${GATEWAY_VENV}/bin/activate"

    # Prefer a project-specific start script if you have it
    if [ -f "${ROOT_DIR}/scripts/start-mcp-gateway.sh" ]; then
      exec bash "${ROOT_DIR}/scripts/start-mcp-gateway.sh"
    fi

    # Else run with Gunicorn+Uvicorn workers (fallback to venv's uvicorn if gunicorn missing)
    local workers
    workers="$(calc_workers "${GW_WORKERS}")"

    if [ -x "${GATEWAY_GUNICORN}" ]; then
      log "Starting MCP‑Gateway (gunicorn) on http://${GW_HOST_LOCAL}:${GW_PORT_LOCAL} (${GW_APP_MODULE}, workers=${workers})"
      exec "${GATEWAY_GUNICORN}" "${GW_APP_MODULE}" \
        -k uvicorn.workers.UvicornWorker \
        --bind "${GW_HOST_LOCAL}:${GW_PORT_LOCAL}" \
        --workers "${workers}" \
        --timeout "${GW_TIMEOUT}" \
        --graceful-timeout "${GW_GRACEFUL_TIMEOUT}" \
        --keep-alive "${GW_KEEPALIVE}" \
        --max-requests "${GW_MAX_REQUESTS}" \
        --max-requests-jitter "${GW_MAX_REQUESTS_JITTER}" \
        --access-logfile "${GW_ACCESS_LOGFILE}" \
        --error-logfile "${GW_ERROR_LOGFILE}" \
        --log-level "${GW_LOG_LEVEL}" \
        --capture-output \
        $( [ "${GW_PRELOAD}" = "true" ] && printf "%s" "--preload" )
    else
      [ -x "${GATEWAY_UVICORN}" ] || err "Gateway gunicorn/uvicorn not found in ${GATEWAY_VENV}. Install dependencies."
      warn "Gateway gunicorn not found; falling back to uvicorn."
      exec "${GATEWAY_UVICORN}" "${GW_APP_MODULE}" \
        --host "${GW_HOST_LOCAL}" --port "${GW_PORT_LOCAL}" --proxy-headers
    fi
  ) &
  GW_PID="$!"
  log "MCP‑Gateway starting (PID ${GW_PID}); waiting for port ${GW_PORT}..."
  if ! wait_for_port "${GW_PORT}" 30; then
    warn "Gateway did not open port ${GW_PORT} within timeout; continuing anyway."
  else
    log "Gateway is listening on port ${GW_PORT}."
  fi
}

# ---------------------------
# Start Matrix Hub (background, subshell)
# ---------------------------
HUB_PID=""
start_hub() {
  [ -f "${HUB_VENV}/bin/activate" ] || err "Matrix Hub venv missing at ${HUB_VENV}. Run 'make setup' first."

  (
    # Load Hub env
    if [ -f "${HUB_ENV_FILE}" ]; then
      # shellcheck disable=SC1090
      set -a; . "${HUB_ENV_FILE}"; set +a
    fi

    local HUB_HOST_LOCAL="${HOST:-${HUB_HOST_DEFAULT}}"
    local HUB_PORT_LOCAL="${PORT:-${HUB_PORT_DEFAULT}}"

    # Fail fast if port busy
    if port_listening "${HUB_PORT_LOCAL}"; then
      err "Port ${HUB_PORT_LOCAL} is already in use. Change PORT in .env or free the port."
    fi

    # Activate Hub venv
    # shellcheck disable=SC1091
    . "${HUB_VENV}/bin/activate"

    # Optional: run DB migrations if Alembic present
    if [ -x "${HUB_VENV}/bin/alembic" ] && [ -f "${ROOT_DIR}/alembic.ini" ]; then
      log "Running Alembic migrations..."
      if ! "${HUB_VENV}/bin/alembic" upgrade head; then
        warn "Alembic migrations failed; continuing."
      fi
    fi

    local workers
    workers="$(calc_workers "${HUB_WORKERS}")"

    if [ -x "${HUB_GUNICORN}" ]; then
      log "Starting Matrix Hub (gunicorn) on http://${HUB_HOST_LOCAL}:${HUB_PORT_LOCAL} (${HUB_APP_MODULE}, workers=${workers})"
      exec "${HUB_GUNICORN}" "${HUB_APP_MODULE}" \
        -k uvicorn.workers.UvicornWorker \
        --bind "${HUB_HOST_LOCAL}:${HUB_PORT_LOCAL}" \
        --workers "${workers}" \
        --timeout "${HUB_TIMEOUT}" \
        --graceful-timeout "${HUB_GRACEFUL_TIMEOUT}" \
        --keep-alive "${HUB_KEEPALIVE}" \
        --max-requests "${HUB_MAX_REQUESTS}" \
        --max-requests-jitter "${HUB_MAX_REQUESTS_JITTER}" \
        --access-logfile "${HUB_ACCESS_LOGFILE}" \
        --error-logfile "${HUB_ERROR_LOGFILE}" \
        --log-level "${HUB_LOG_LEVEL}" \
        --capture-output \
        $( [ "${HUB_PRELOAD}" = "true" ] && printf "%s" "--preload" )
    else
      [ -x "${HUB_UVICORN}" ] || err "Hub gunicorn/uvicorn not found in ${HUB_VENV}. Run 'make setup'."
      warn "Hub gunicorn not found; falling back to uvicorn."
      exec "${HUB_UVICORN}" "${HUB_APP_MODULE}" \
        --host "${HUB_HOST_LOCAL}" --port "${HUB_PORT_LOCAL}" --proxy-headers
    fi
  ) &
  HUB_PID="$!"
}

# ---------------------------
# Shutdown / supervision
# ---------------------------
stop_pid() {
  local pid="$1" name="$2"
  if [ -n "${pid}" ] && kill -0 "${pid}" >/dev/null 2>&1; then
    log "Stopping ${name} (PID ${pid})..."
    kill "${pid}" >/dev/null 2>&1 || true
    # give it up to 20s to exit gracefully, then SIGKILL
    for i in $(seq 1 20); do
      if ! kill -0 "${pid}" >/dev/null 2>&1; then
        return 0
      fi
      sleep 1
    done
    warn "${name} did not exit gracefully; sending SIGKILL."
    kill -9 "${pid}" >/dev/null 2>&1 || true
  fi
}

cleanup() {
  # Stop in reverse dependency order: Hub first, then Gateway we started
  stop_pid "${HUB_PID}" "Matrix Hub"
  # Only stop gateway if we started it (PID known & alive)
  if [ -n "${GW_PID}" ] && kill -0 "${GW_PID}" >/dev/null 2>&1; then
    stop_pid "${GW_PID}" "MCP‑Gateway"
  fi
}
trap cleanup EXIT INT TERM

# ---------------------------
# Run
# ---------------------------
start_gateway
start_hub

# Wait for either to exit, then shut down the other
exit_code=0
if wait -n "${HUB_PID}" "${GW_PID}" 2>/dev/null; then
  # One exited normally; fetch its status
  wait "${HUB_PID}" 2>/dev/null || exit_code=$?
  wait "${GW_PID}" 2>/dev/null || true
else
  # Fallback (shells without wait -n): just wait on hub; gateway is best-effort
  wait "${HUB_PID}" || exit_code=$?
  wait "${GW_PID}" || true
fi

exit "${exit_code}"
