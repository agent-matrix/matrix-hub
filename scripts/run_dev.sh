#!/usr/bin/env bash
# scripts/run_dev.sh
# Run MCP‑Gateway (using mcpgateway/.venv) and then Matrix Hub (using ./.venv),
# keeping environments isolated and using each venv's uvicorn explicitly.

set -Eeuo pipefail

# ---------------------------
# Paths & defaults
# ---------------------------
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

# Gateway
GATEWAY_DIR="${GATEWAY_DIR:-${ROOT_DIR}/mcpgateway}"
GATEWAY_ENV_LOCAL="${GATEWAY_ENV_LOCAL:-${ROOT_DIR}/.env.gateway.local}"
GATEWAY_ENV_FILE="${GATEWAY_ENV_FILE:-${GATEWAY_DIR}/.env}"
GATEWAY_VENV="${GATEWAY_DIR}/.venv"
GATEWAY_UVICORN="${GATEWAY_VENV}/bin/uvicorn"
GATEWAY_PYTHON="${GATEWAY_VENV}/bin/python"
GATEWAY_HOST_DEFAULT="0.0.0.0"
GATEWAY_PORT_DEFAULT="4444"
# Allow override of gateway app module if fallback is used
GW_APP_MODULE="${GW_APP_MODULE:-mcp_gateway.app:app}"

# Hub
HUB_ENV_FILE="${HUB_ENV_FILE:-${ROOT_DIR}/.env}"
HUB_ENV_EXAMPLE="${HUB_ENV_EXAMPLE:-${ROOT_DIR}/.env.example}"
HUB_VENV="${ROOT_DIR}/.venv"
HUB_UVICORN="${HUB_VENV}/bin/uvicorn"
HUB_PYTHON="${HUB_VENV}/bin/python"
HUB_HOST_DEFAULT="0.0.0.0"
HUB_PORT_DEFAULT="443"
APP_MODULE="${APP_MODULE:-src.app:app}"

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
    # best-effort fallback (bash TCP)
    (echo >/dev/tcp/127.0.0.1/"${port}") >/dev/null 2>&1
  fi
}

wait_for_port() {
  local port="$1" timeout="${2:-20}" waited=0
  while ! port_listening "${port}"; do
    sleep 1
    waited=$((waited+1))
    if [ "${waited}" -ge "${timeout}" ]; then
      return 1
    fi
  done
  return 0
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
# Start MCP‑Gateway (subshell; no env leakage)
# ---------------------------
GW_PID=""
if [ "${GATEWAY_SKIP_START}" != "1" ]; then
  if port_listening "${GW_PORT}"; then
    log "MCP‑Gateway already listening on port ${GW_PORT}; will not start another instance."
  else
    [ -d "${GATEWAY_DIR}" ] || err "Gateway project not found at ${GATEWAY_DIR}. Run setup (scripts/setup-mcp-gateway.sh) first."
    [ -f "${GATEWAY_VENV}/bin/activate" ] || err "Gateway venv missing at ${GATEWAY_VENV}. Run gateway setup first."

    # Ensure gateway .env exists
    if [ ! -f "${GATEWAY_ENV_FILE}" ] && [ -f "${GATEWAY_ENV_LOCAL}" ]; then
      cp "${GATEWAY_ENV_LOCAL}" "${GATEWAY_ENV_FILE}"
      log "Created ${GATEWAY_ENV_FILE} from ${GATEWAY_ENV_LOCAL}"
    fi

    (
      cd "${GATEWAY_DIR}"

      # Load gateway env if present (only in this subshell)
      if [ -f ".env" ]; then
        # shellcheck disable=SC1091
        set -a; . ".env"; set +a
      fi

      # Activate gateway venv
      # shellcheck disable=SC1091
      . "${GATEWAY_VENV}/bin/activate"

      # If a start script exists in root/scripts, prefer it (run with bash even if not +x)
      if [ -f "${ROOT_DIR}/scripts/start-mcp-gateway.sh" ]; then
        exec bash "${ROOT_DIR}/scripts/start-mcp-gateway.sh"
      fi

      # Fallback: use gateway venv's uvicorn
      GW_HOST_LOCAL="${HOST:-${GATEWAY_HOST_DEFAULT}}"
      GW_PORT_LOCAL="${PORT:-${GATEWAY_PORT_DEFAULT}}"

      if [ ! -x "${GATEWAY_UVICORN}" ]; then
        err "Gateway uvicorn not found at ${GATEWAY_UVICORN}. Did gateway setup install dependencies?"
      fi

      log "Starting MCP‑Gateway via uvicorn on http://${GW_HOST_LOCAL}:${GW_PORT_LOCAL} (${GW_APP_MODULE})"
      exec "${GATEWAY_UVICORN}" "${GW_APP_MODULE}" --host "${GW_HOST_LOCAL}" --port "${GW_PORT_LOCAL}" --proxy-headers
    ) &
    GW_PID="$!"
    log "MCP‑Gateway starting (PID ${GW_PID}); waiting for port ${GW_PORT}..."
    if ! wait_for_port "${GW_PORT}" 25; then
      warn "Gateway did not open port ${GW_PORT} within timeout; continuing anyway."
    else
      log "Gateway is listening on port ${GW_PORT}."
    fi
  fi
else
  log "Skipping MCP‑Gateway start (GATEWAY_SKIP_START=1)."
fi

cleanup() {
  # Stop only the gateway we started (do not kill an externally running one)
  if [ -n "${GW_PID}" ] && kill -0 "${GW_PID}" >/dev/null 2>&1; then
    log "Stopping MCP‑Gateway (PID ${GW_PID})..."
    kill "${GW_PID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

# ---------------------------
# Ensure Matrix Hub .env exists
# ---------------------------
if [ ! -f "${HUB_ENV_FILE}" ] && [ -f "${HUB_ENV_EXAMPLE}" ]; then
  cp "${HUB_ENV_EXAMPLE}" "${HUB_ENV_FILE}"
  log "Created ${HUB_ENV_FILE} from ${HUB_ENV_EXAMPLE}"
fi

# Load Hub env (in current shell)
if [ -f "${HUB_ENV_FILE}" ]; then
  # shellcheck disable=SC1090
  set -a; . "${HUB_ENV_FILE}"; set +a
fi

# Resolve hub host/port without polluting env for gateway
HUB_HOST="${HOST:-${HUB_HOST_DEFAULT}}"
HUB_PORT="${PORT:-${HUB_PORT_DEFAULT}}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"

# ---------------------------
# Activate Hub venv & sanity check
# ---------------------------
[ -f "${HUB_VENV}/bin/activate" ] || err "Matrix Hub venv missing at ${HUB_VENV}. Run 'make setup' first."
# shellcheck disable=SC1091
. "${HUB_VENV}/bin/activate"

# Use venv's uvicorn explicitly to avoid global uvicorn
[ -x "${HUB_UVICORN}" ] || err "uvicorn not found at ${HUB_UVICORN}. Run 'make setup' to install dependencies."

# Optional helpful check: if sqlalchemy is not installed, tell the user how to fix
if ! "${HUB_PYTHON}" -c 'import sqlalchemy' 2>/dev/null; then
  warn "SQLAlchemy not found in Matrix Hub venv. Run: make setup"
fi

# Fail fast if port busy
if port_listening "${HUB_PORT}"; then
  err "Port ${HUB_PORT} is already in use. Change PORT in .env or free the port."
fi

log "Starting Matrix Hub (dev) on http://${HUB_HOST}:${HUB_PORT}"
log "  APP_MODULE=${APP_MODULE}"
log "  LOG_LEVEL=${LOG_LEVEL}"

exec "${HUB_UVICORN}" "${APP_MODULE}" --reload \
  --host "${HUB_HOST}" --port "${HUB_PORT}" --proxy-headers \
  --log-level debug
