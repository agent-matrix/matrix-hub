#!/usr/bin/env bash
#
# setup-mcp-gateway.sh - Unified Installer (& optional Launcher) for MCP-Gateway
#
# This script provides a one-shot, production-ready workflow to set up and
# optionally run the MCP Gateway. It is idempotent and suitable for CI/CD.
#
# Features:
# - Parses command-line arguments for custom configuration.
# - Installs OS dependencies (macOS, Debian/Ubuntu, RHEL/Fedora) — can be skipped.
# - Checks/installs Python 3.11 (Linux helper script) — can be skipped.
# - Clones or updates the MCP Gateway git repository.
# - Creates a Python virtual environment and installs dependencies.
# - Generates a secure, default .env file if one doesn't exist — can be skipped.
# - (Optional) Initializes the database and starts the gateway + health check.
#
# Usage:
#   ./scripts/setup-mcp-gateway.sh [--project-dir ./mcpgateway] [--branch main] [--force] [--non-interactive]
#
# Container-friendly env switches:
#   SKIP_OS_DEPS=1       # do not install OS packages (Dockerfile does it already)
#   SKIP_PYTHON_CHECK=1  # do not attempt to install Python
#   SETUP_ONLY=1         # do not start processes or open ports; just set up venv/deps
#   GENERATE_ENV=0       # do not create mcpgateway/.env automatically
#   PIP_QUIET=1          # quiet pip output (default: 1)
#   DEBIAN_FRONTEND=noninteractive  # default set here; safe for apt-get
#

set -Eeuo pipefail

# --- Defaults & Flags ---
PROJECT_DIR_NAME="mcpgateway"
BRANCH="main"
HOST="0.0.0.0"
PORT="4444"
NON_INTERACTIVE="false"
FORCE="false"

# Container-friendly toggles (can be overridden via environment)
SKIP_OS_DEPS="${SKIP_OS_DEPS:-0}"
SKIP_PYTHON_CHECK="${SKIP_PYTHON_CHECK:-0}"
SETUP_ONLY="${SETUP_ONLY:-0}"
GENERATE_ENV="${GENERATE_ENV:-1}"
PIP_QUIET="${PIP_QUIET:-1}"
export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"

# Python binary preference
PY_BIN="${PY_BIN:-}"

# --- Dynamic Paths ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "${SCRIPT_DIR}")"
PROJECT_DIR="${BASE_DIR}/${PROJECT_DIR_NAME}"
VENV_DIR="${PROJECT_DIR}/.venv"
ENV_FILE="${PROJECT_DIR}/.env"
LOG_DIR="${PROJECT_DIR}/logs"
LOG_FILE="${LOG_DIR}/mcpgateway.log"
INSTALL_PYTHON_SCRIPT="${SCRIPT_DIR}/install_python.sh"

# --- Helper Functions ---
log() { printf "\n[$(date +'%F %T')] %s\n" "$*"; }
die() { printf "\nERROR: %s\n" "$*" >&2; exit 1; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

# sudo-less root execution wrapper (works in Docker)
SUDO_BIN="$(command -v sudo || true)"
run_root() {
  if [ -n "${SUDO_BIN}" ]; then
    sudo "$@"
    return
  fi
  if [ "$(id -u)" = "0" ]; then
    "$@"
    return
  fi
  if [ "${SKIP_OS_DEPS}" = "1" ]; then
    log "[setup] SKIP_OS_DEPS=1 set; skipping: $*"
    return
  fi
  die "Need root privileges to run: $* (install sudo or run as root)"
}

# Safer pip verbosity
pip_run() {
  if [ "${PIP_QUIET}" = "1" ]; then
    pip -q "$@"
  else
    pip "$@"
  fi
}

# =============================================================================
# PHASE 1: SYSTEM & PROJECT SETUP
# =============================================================================
log "### PHASE 1: SYSTEM & PROJECT SETUP ###"

# --- 1.1 Install OS Dependencies ---
install_os_deps() {
  if [[ "${SKIP_OS_DEPS}" = "1" ]]; then
    log "Skipping OS dependency installation (SKIP_OS_DEPS=1)."
    return
  fi

  log "Checking OS and installing dependencies..."
  if [[ "$(uname)" == "Darwin" ]]; then
    log "🍏 macOS detected. Verifying tools (git, curl)..."
    for tool in git curl; do
      have_cmd "${tool}" || die "Tool '${tool}' not found. Please install it (e.g., 'brew install ${tool}')."
    done
  elif have_cmd apt-get; then
    log "🐧 Debian/Ubuntu detected. Installing packages..."
    run_root apt-get update -y
    run_root apt-get install -y --no-install-recommends \
      git curl build-essential libffi-dev libssl-dev ca-certificates
  elif have_cmd dnf; then
    log "🐧 RHEL/Fedora detected. Installing packages..."
    run_root dnf install -y git curl gcc-c++ make libffi-devel openssl-devel
  else
    log "Unsupported OS package manager – skipping OS deps. Ensure git & curl are available."
  fi
  log "✅ OS dependencies are satisfied (or skipped)."
}

# --- 1.2 Determine Python binary & (optionally) Install Python 3.11 ---
ensure_python() {
  if [[ -n "${PY_BIN}" && ! "$(have_cmd "${PY_BIN}"; echo $?)" = "0" ]]; then
    die "PY_BIN='${PY_BIN}' not found in PATH."
  fi

  if [[ -z "${PY_BIN}" ]]; then
    if have_cmd python3.11; then
      PY_BIN="python3.11"
    elif have_cmd python3; then
      PY_BIN="python3"
    else
      PY_BIN=""
    fi
  fi

  if [[ -n "${PY_BIN}" ]]; then
    log "Using Python interpreter: ${PY_BIN} ($(${PY_BIN} -V 2>/dev/null || echo unknown))"
    return
  fi

  if [[ "${SKIP_PYTHON_CHECK}" = "1" ]]; then
    die "No suitable Python found and SKIP_PYTHON_CHECK=1. Install Python 3.11 or set PY_BIN."
  fi

  log "❌ Python 3.11 not found."
  if [[ "$(uname)" == "Linux" ]] && [ -f "${INSTALL_PYTHON_SCRIPT}" ]; then
    log "🚀 Running the Python installer script for Linux..."
    chmod +x "${INSTALL_PYTHON_SCRIPT}"
    "${INSTALL_PYTHON_SCRIPT}"
    if have_cmd python3.11; then
      PY_BIN="python3.11"
    elif have_cmd python3; then
      PY_BIN="python3"
    else
      die "Python installation failed; no python3 available."
    fi
  else
    die "Please install Python 3.11 manually. On macOS: 'brew install python@3.11'."
  fi
  log "✅ Python installed successfully."
}

# --- 1.3 Fetch Git Repository ---
fetch_repo() {
  if [[ -d "${PROJECT_DIR}/.git" ]]; then
    log "🔄 Git repository already exists at ${PROJECT_DIR}."
    # Best-effort update same branch
    ( cd "${PROJECT_DIR}" && git fetch --depth 1 origin "${BRANCH}" || true; \
      git checkout "${BRANCH}" || true; \
      git pull --ff-only origin "${BRANCH}" || true ) || true
  else
    log "⏳ Cloning IBM/mcp-context-forge (branch: ${BRANCH}) into ${PROJECT_DIR}..."
    git clone --branch "${BRANCH}" --depth 1 https://github.com/IBM/mcp-context-forge.git "${PROJECT_DIR}"
  fi
}

# --- 1.4 Setup Python Virtual Environment ---
setup_venv() {
  if [[ -d "${VENV_DIR}" && "${FORCE}" == "true" ]]; then
    log "🗑  Removing existing virtual environment (as per --force flag)..."
    rm -rf "${VENV_DIR}"
  fi

  if [[ ! -d "${VENV_DIR}" ]]; then
    log "🐍 Creating Python virtual environment at ${VENV_DIR}..."
    "${PY_BIN}" -m venv "${VENV_DIR}"
  fi

  log "📦 Activating virtual environment and installing dependencies..."
  # shellcheck disable=SC1090
  source "${VENV_DIR}/bin/activate"
  pip_run install --upgrade pip setuptools wheel
  pushd "${PROJECT_DIR}" >/dev/null
    # Try dev extras first; fall back to editable; then plain install.
    pip_run install -e '.[dev]' || pip_run install -e . || pip_run install .
  popd >/dev/null
  log "✅ Python dependencies are installed."
}

# =============================================================================
# PHASE 2: CONFIGURATION
# =============================================================================
log "### PHASE 2: CONFIGURATION ###"

ensure_env_file() {
  mkdir -p "${LOG_DIR}"
  if [[ "${GENERATE_ENV}" != "1" ]]; then
    log "Skipping .env generation (GENERATE_ENV=0)."
    return
  fi

  if [[ -f "${ENV_FILE}" ]]; then
    log "✅ Using existing .env file: ${ENV_FILE}"
    return
  fi

  log "⏳ No .env file found. Creating one with secure, random defaults..."
  # Generate tokens (openssl fallback to Python secrets)
  if have_cmd openssl; then
    RAND_PASS="$(openssl rand -hex 16)"
    RAND_JWT="$(openssl rand -hex 24)"
  else
    RAND_PASS="$("${PY_BIN}" - <<'PY'
import secrets; print(secrets.token_hex(16))
PY
)"
    RAND_JWT="$("${PY_BIN}" - <<'PY'
import secrets; print(secrets.token_hex(24))
PY
)"
  fi

  cat > "${ENV_FILE}" <<EOF
# --- MCP Gateway .env (autogenerated by setup-mcp-gateway.sh) ---
HOST=${HOST}
PORT=${PORT}
BASIC_AUTH_USER=admin
BASIC_AUTH_PASSWORD=${RAND_PASS}
JWT_SECRET_KEY=${RAND_JWT}
JWT_ALGORITHM=HS256
TOKEN_EXPIRY=10080
DATABASE_URL=sqlite:///./mcp.db
LOG_LEVEL=INFO
MCPGATEWAY_UI_ENABLED=true
MCPGATEWAY_ADMIN_API_ENABLED=true
CORS_ENABLED=true
ALLOWED_ORIGINS=["http://localhost","http://localhost:${PORT}"]
EOF
  log "✅ Wrote new configuration to ${ENV_FILE}."
  log "ℹ️  Default username is 'admin', with a randomly generated password."
}

# =============================================================================
# PHASE 3: EXECUTION (optional; skipped in Docker build via SETUP_ONLY=1)
# =============================================================================
log "### PHASE 3: GATEWAY EXECUTION ###"

init_db() {
  # shellcheck disable=SC1090
  source "${VENV_DIR}/bin/activate"
  pushd "${PROJECT_DIR}" >/dev/null
    log "⏳ Initializing gateway database..."
    # This assumes the gateway package exposes a db init module/CLI. Adjust if needed.
    python - <<'PY'
try:
    # Example: import and run db init if available
    import importlib
    for name in ("mcp_gateway.db", "mcpgateway.db", "mcpgateway.database"):
        try:
            mdl = importlib.import_module(name)
            if hasattr(mdl, "main"):
                mdl.main()
                raise SystemExit(0)
        except ModuleNotFoundError:
            continue
    print("No explicit DB init module found; skipping.", flush=True)
except Exception as e:
    print(f"DB init warning: {e}", flush=True)
PY
  popd >/dev/null
  log "✅ Database init step completed (or skipped)."
}

start_gateway() {
  # If a process is listening, try to stop it (local dev)
  if have_cmd lsof && lsof -iTCP:"${PORT}" -sTCP:LISTEN -t >/dev/null 2>&1; then
    if [[ "${NON_INTERACTIVE}" == "true" || "${FORCE}" == "true" ]]; then
      log "⚠️ Port ${PORT} is in use. Stopping existing process..."
      lsof -iTCP:"${PORT}" -sTCP:LISTEN -t | xargs -r kill -9 || true
      sleep 1
    else
      read -r -p "⚠️ Port ${PORT} is in use. Stop the existing process and continue? [y/N] " r || true
      if [[ "${r:-N}" != "y" && "${r:-N}" != "Y" ]]; then
        die "Port conflict; aborting."
      fi
      lsof -iTCP:"${PORT}" -sTCP:LISTEN -t | xargs -r kill -9 || true
      sleep 1
    fi
  fi

  # shellcheck disable=SC1090
  source "${VENV_DIR}/bin/activate"
  set -o allexport
  # shellcheck disable=SC1090
  [ -f "${ENV_FILE}" ] && source "${ENV_FILE}"
  set +o allexport

  pushd "${PROJECT_DIR}" >/dev/null
    log "▶️ Starting MCP Gateway on ${HOST}:${PORT}..."
    # Prefer gunicorn if available
    if have_cmd gunicorn; then
      # Try common app modules (adjust if your gateway entrypoint differs)
      APP_MOD="${GW_APP_MODULE:-mcp_gateway.app:app}"
      nohup gunicorn "${APP_MOD}" \
        --workers "${GW_WORKERS:-3}" \
        --worker-class uvicorn.workers.UvicornWorker \
        --bind "${HOST}:${PORT}" \
        --timeout "${GW_TIMEOUT:-60}" \
        --graceful-timeout "${GW_GRACEFUL_TIMEOUT:-30}" \
        --keep-alive "${GW_KEEPALIVE:-5}" \
        --max-requests "${GW_MAX_REQUESTS:-0}" \
        --max-requests-jitter "${GW_MAX_REQUESTS_JITTER:-0}" \
        --preload $([ "${GW_PRELOAD:-false}" = "true" ] && echo "--preload") \
        > "${LOG_FILE}" 2>&1 &
      GATEWAY_PID=$!
    else
      # Fallback: uvicorn CLI
      APP_MOD="${GW_APP_MODULE:-mcp_gateway.app:app}"
      nohup uvicorn "${APP_MOD}" --host "${HOST}" --port "${PORT}" --proxy-headers \
        > "${LOG_FILE}" 2>&1 &
      GATEWAY_PID=$!
    fi
  popd >/dev/null

  echo "${GATEWAY_PID}" > "${PROJECT_DIR}/mcpgateway.pid"
  log "✅ MCP Gateway started (PID: ${GATEWAY_PID}). Logs: ${LOG_FILE}"
}

wait_for_health() {
  local url="http://127.0.0.1:${PORT}/health"
  log "⏳ Waiting for gateway to become healthy at ${url}..."
  for i in {1..30}; do
    if curl -fsS "${url}" >/dev/null 2>&1; then
      local admin_url="http://localhost:${PORT}/admin/"
      log "🎉 Gateway is healthy and running!"
      log "➡️  Admin UI: ${admin_url}"
      return 0
    fi
    sleep 2
  done
  log "Gateway did not become healthy in time. Check logs: ${LOG_FILE}"
  return 1
}

# --- Argument Parsing (after functions so help is available even on parse errors) ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-dir) PROJECT_DIR_NAME="$2"; PROJECT_DIR="${BASE_DIR}/${PROJECT_DIR_NAME}"; VENV_DIR="${PROJECT_DIR}/.venv"; ENV_FILE="${PROJECT_DIR}/.env"; shift 2 ;;
    --branch)      BRANCH="$2"; shift 2 ;;
    --host)        HOST="$2"; shift 2 ;;
    --port)        PORT="$2"; shift 2 ;;
    --force)       FORCE="true"; shift 1 ;;
    --non-interactive) NON_INTERACTIVE="true"; shift 1 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

# --- Main Execution ---
main() {
  install_os_deps
  ensure_python
  fetch_repo
  setup_venv

  # .env is typically safe to generate in dev; allow skip in CI/builds
  ensure_env_file

  if [[ "${SETUP_ONLY}" = "1" ]]; then
    log "SETUP_ONLY=1 → Skipping DB init, start, and health check."
    return 0
  fi

  init_db
  start_gateway
  #wait_for_health
}

main "$@"
