#!/usr/bin/env bash
#
# setup-mcp-gateway.sh - Unified Installer & Launcher for MCP-Gateway.
#
# Idempotent. Suitable for CI/CD and operator one-shot.
#
# Usage:
#   ./setup-mcp-gateway.sh [--project-dir ./mcpgateway] [--branch v0.4.0]
#                          [--force] [--non-interactive] [--no-start]
#
# Notes:
#   --no-start  Skip starting the gateway (install + DB-init only). Used
#               by the top-level Makefile so `make install` doesn't start
#               services that `make run` would then try to start again on
#               the same port (4444 collision).
#

set -Eeuo pipefail

# WSL friendliness: avoid uv hardlink-fallback warning when the project
# tree (typically /mnt/c) and uv's cache (~/.cache/uv on Linux ext4)
# live on different filesystems.
export UV_LINK_MODE="${UV_LINK_MODE:-copy}"

# --- Defaults & Flags ---
PROJECT_DIR_NAME="mcpgateway"
BRANCH="v0.4.0"
HOST="0.0.0.0"
PORT="4444"
NON_INTERACTIVE="false"
FORCE="false"
NO_START="false"

# --- Dynamic Paths ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "${SCRIPT_DIR}")"
PROJECT_DIR="${BASE_DIR}/${PROJECT_DIR_NAME}"
VENV_DIR="${PROJECT_DIR}/.venv"
ENV_FILE="${PROJECT_DIR}/.env"
LOG_DIR="${PROJECT_DIR}/logs"
LOG_FILE="${LOG_DIR}/mcpgateway.log"
INSTALL_PYTHON_SCRIPT="${SCRIPT_DIR}/install_python.sh"


# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-dir) PROJECT_DIR_NAME="$2"; shift 2 ;;
    --branch)      BRANCH="$2"; shift 2 ;;
    --host)        HOST="$2"; shift 2 ;;
    --port)        PORT="$2"; shift 2 ;;
    --force)       FORCE="true"; shift 1 ;;
    --non-interactive) NON_INTERACTIVE="true"; shift 1 ;;
    --no-start)    NO_START="true"; shift 1 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done


# --- Helper Functions ---
log() { printf "\n[$(date +'%F %T')] %s\n" "$*"; }
die() { printf "\nERROR: %s\n" "$*" >&2; exit 1; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

is_uv_managed_python() {
  local p resolved
  p="$1"
  resolved="$(readlink -f "$p" 2>/dev/null || echo "$p")"
  case "$resolved" in
    */uv/python/*|*/.local/share/uv/python/*) return 0 ;;
    *) return 1 ;;
  esac
}

pick_python311() {
  local cand
  for cand in /usr/bin/python3.11 /usr/local/bin/python3.11 /opt/python3.11/bin/python3.11; do
    if [ -x "$cand" ] && ! is_uv_managed_python "$cand"; then
      echo "$cand"
      return 0
    fi
  done
  if have_cmd python3.11; then
    cand="$(command -v python3.11)"
    if ! is_uv_managed_python "$cand"; then
      echo "$cand"
      return 0
    fi
  fi
  return 1
}

venv_pip() {
  if have_cmd uv; then
    uv pip "$@"
  else
    pip "$@"
  fi
}


# =============================================================================
# PHASE 1: SYSTEM & PROJECT SETUP
# =============================================================================
log "### PHASE 1: SYSTEM & PROJECT SETUP ###"

install_os_deps() {
  log "Checking OS and installing dependencies..."
  if [[ "$(uname)" == "Darwin" ]]; then
    log "🍏 macOS detected. Verifying tools (git, curl, jq)..."
    for tool in git curl jq; do
      have_cmd "${tool}" || die "Tool '${tool}' not found. Please install it (e.g., 'brew install ${tool}')."
    done
  elif have_cmd apt-get; then
    log "🐧 Debian/Ubuntu detected. Installing packages..."
    sudo apt-get update -y
    sudo apt-get install -y git curl jq build-essential libffi-dev libssl-dev
    sudo apt-get install -y python3.11 python3.11-venv python3.11-distutils 2>/dev/null \
      || log "ℹ️  python3.11 system packages not installable from current apt sources — setup_venv() will self-heal if needed."
  elif have_cmd dnf; then
    log "🐧 RHEL/Fedora detected. Installing packages..."
    sudo dnf install -y git curl jq gcc-c++ make libffi-devel openssl-devel
  else
    die "Unsupported OS. Please install required tools manually: git, curl, jq, and Python 3.11 build dependencies."
  fi
  log "✅ OS dependencies are satisfied."
}

ensure_python() {
  log "Checking for Python 3.11..."
  if pick_python311 >/dev/null 2>&1; then
    log "✅ System Python 3.11 found at: $(pick_python311)"
    return
  fi
  if have_cmd uv; then
    log "✅ uv detected — setup_venv() will use 'uv venv' to handle Python 3.11."
    return
  fi
  if have_cmd python3.11; then
    local p; p="$(command -v python3.11)"
    if is_uv_managed_python "$p"; then
      log "ℹ️  Found python3.11 at $p but it is uv-managed. Will install a system python3.11 alongside it."
    fi
  fi
  log "❌ No usable system Python 3.11 found."
  if [[ "$(uname)" == "Linux" ]] && [ -f "${INSTALL_PYTHON_SCRIPT}" ]; then
    log "🚀 Running the Python installer script for Linux..."
    chmod +x "${INSTALL_PYTHON_SCRIPT}"
    "${INSTALL_PYTHON_SCRIPT}"
    pick_python311 >/dev/null 2>&1 || have_cmd uv \
      || die "Python 3.11 installation failed. Try: sudo apt install -y python3.11 python3.11-venv python3.11-distutils"
  else
    die "Please install Python 3.11 manually."
  fi
  log "✅ Python 3.11 installed successfully."
}

fetch_repo() {
  if [[ -d "${PROJECT_DIR}/.git" ]]; then
    log "🔄 Git repository already exists at ${PROJECT_DIR}."
  else
    log "⏳ Cloning IBM/mcp-context-forge (branch: ${BRANCH}) into ${PROJECT_DIR}..."
    git clone --branch "${BRANCH}" --depth 1 https://github.com/IBM/mcp-context-forge.git "${PROJECT_DIR}"
  fi
}

setup_venv() {
  if [[ -d "${VENV_DIR}" && "${FORCE}" == "true" ]]; then
    log "🗑 Removing existing virtual environment (as per --force flag)..."
    rm -rf "${VENV_DIR}"
  fi
  if [[ -d "${VENV_DIR}" ]] && [[ ! -f "${VENV_DIR}/bin/activate" ]]; then
    log "🗑 Removing half-built venv at ${VENV_DIR}..."
    rm -rf "${VENV_DIR}"
  fi

  if [[ ! -f "${VENV_DIR}/bin/activate" ]]; then
    log "🐍 [1/3] Creating Python 3.11 virtual environment at ${VENV_DIR}..."

    if have_cmd uv; then
      log "     Using 'uv venv --python 3.11'..."
      if uv venv --python 3.11 "${VENV_DIR}" 2>/tmp/_venv.err; then
        log "     ✅ venv created via uv."
      else
        cat /tmp/_venv.err >&2 || true
        log "     ⚠️  uv venv failed; falling back to system python3.11..."
        rm -rf "${VENV_DIR}"
      fi
    fi

    if [[ ! -f "${VENV_DIR}/bin/activate" ]]; then
      PY311="$(pick_python311 || true)"
      [ -n "${PY311}" ] || die "Couldn't find a usable system python3.11. Install python3.11 + python3.11-venv (or uv)."
      log "     Using ${PY311} -m venv ..."
      venv_err="$(mktemp)"
      if "${PY311}" -m venv "${VENV_DIR}" 2>"${venv_err}"; then
        log "     ✅ venv created via ${PY311}."
      else
        cat "${venv_err}" >&2 || true
        rm -rf "${VENV_DIR}"
        if have_cmd apt-get; then
          log "     🔧 Installing python3.11-venv via apt and retrying..."
          sudo apt-get update -y || true
          if sudo apt-get install -y python3.11-venv python3.11-distutils 2>/dev/null \
             && "${PY311}" -m venv "${VENV_DIR}" 2>"${venv_err}"; then
            log "     ✅ venv created after installing python3.11-venv."
          else
            rm -rf "${VENV_DIR}"
          fi
        fi
        if [[ ! -f "${VENV_DIR}/bin/activate" ]]; then
          log "     🔧 Trying --without-pip + get-pip.py bootstrap..."
          "${PY311}" -m venv --without-pip "${VENV_DIR}" 2>"${venv_err}" \
            || die "Could not create venv. Try: sudo apt install -y python3.11 python3.11-venv"
          gp="$(mktemp --suffix=.py)"
          curl -fsSL https://bootstrap.pypa.io/get-pip.py -o "${gp}" \
            || die "Failed to download get-pip.py — check network."
          "${VENV_DIR}/bin/python3" "${gp}" \
            || die "get-pip.py bootstrap failed."
          rm -f "${gp}"
          log "     ✅ pip bootstrapped via get-pip.py."
        fi
      fi
      rm -f "${venv_err}"
    fi
  fi

  log "📦 [2/3] Activating venv and upgrading pip/setuptools/wheel..."
  # shellcheck disable=SC1090
  source "${VENV_DIR}/bin/activate"
  venv_pip install --upgrade pip setuptools wheel

  log "📦 [3/3] Installing mcp-context-forge into the gateway venv (~30-90s on first run)..."
  pushd "${PROJECT_DIR}" >/dev/null
    venv_pip install -e '.[dev]' || venv_pip install -e .
  popd >/dev/null
  log "✅ Python dependencies are installed."
}


# =============================================================================
# PHASE 2: CONFIGURATION
# =============================================================================
log "### PHASE 2: CONFIGURATION ###"

ensure_env_file() {
  mkdir -p "${LOG_DIR}"
  if [[ -f "${ENV_FILE}" ]]; then
    log "✅ Using existing .env file: ${ENV_FILE}"
    return
  fi
  log "⏳ No .env file found. Creating one with secure, random defaults..."
  RAND_PASS="$(openssl rand -hex 16)"
  RAND_JWT="$(openssl rand -hex 24)"
  cat > "${ENV_FILE}" <<EOF
# --- MCP Gateway .env (autogenerated) ---
HOST=${HOST}
PORT=${PORT}
BASIC_AUTH_USERNAME=admin
BASIC_AUTH_PASSWORD=${RAND_PASS}
JWT_SECRET_KEY=${RAND_JWT}
DATABASE_URL=sqlite:///./gateway.sqlite
LOG_LEVEL=INFO
EOF
  log "✅ Wrote new configuration to ${ENV_FILE}."
}


# =============================================================================
# PHASE 3: EXECUTION
# =============================================================================
log "### PHASE 3: GATEWAY EXECUTION ###"

init_db() {
  # shellcheck disable=SC1090
  source "${VENV_DIR}/bin/activate"
  pushd "${PROJECT_DIR}" >/dev/null
    log "⏳ Initializing gateway database..."
    python -m mcpgateway.db
  popd >/dev/null
  log "✅ Database initialized."
}

start_gateway() {
  if lsof -iTCP:"${PORT}" -sTCP:LISTEN -t >/dev/null 2>&1; then
    if [[ "${NON_INTERACTIVE}" == "true" || "${FORCE}" == "true" ]]; then
      log "⚠️ Port ${PORT} is in use. Stopping existing process..."
      lsof -iTCP:"${PORT}" -sTCP:LISTEN -t | xargs kill -9
      sleep 1
    else
      read -r -p "⚠️ Port ${PORT} is in use. Stop the existing process and continue? [y/N] " r
      if [[ "${r,,}" != "y" ]]; then
        die "Port conflict; aborting."
      fi
      lsof -iTCP:"${PORT}" -sTCP:LISTEN -t | xargs kill -9
      sleep 1
    fi
  fi

  # shellcheck disable=SC1090
  source "${VENV_DIR}/bin/activate"
  set -o allexport
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +o allexport

  pushd "${PROJECT_DIR}" >/dev/null
    log "▶️ Starting MCP Gateway on ${HOST}:${PORT}..."
    nohup mcpgateway --host "${HOST}" --port "${PORT}" > "${LOG_FILE}" 2>&1 &
    GATEWAY_PID=$!
  popd >/dev/null
  echo "${GATEWAY_PID}" > "${PROJECT_DIR}/mcpgateway.pid"
  log "✅ MCP Gateway started (PID: ${GATEWAY_PID}). Logs are at ${LOG_FILE}"
}

wait_for_health() {
  local url="http://127.0.0.1:${PORT}/health"
  log "⏳ Waiting for gateway to become healthy at ${url}..."
  for i in {1..30}; do
    if curl -fsS "${url}" >/dev/null 2>&1; then
      log "🎉 Gateway is healthy and running!"
      log "➡️ Admin UI available at: http://localhost:${PORT}/admin/"
      return 0
    fi
    sleep 2
  done
  die "Gateway did not become healthy in time. Check logs: tail -f ${LOG_FILE}"
}


# --- Main Execution ---
main() {
  install_os_deps
  ensure_python
  fetch_repo
  setup_venv
  ensure_env_file
  init_db

  if [[ "${NO_START}" == "true" ]]; then
    log "ℹ️  --no-start passed: skipping start_gateway and wait_for_health."
    log "   The MCP Gateway is INSTALLED and the DB is INITIALIZED."
    log "   To launch it later, run \`make run\` (Hub + Gateway, prod mode)"
    log "   or \`make gateway-start\` (gateway only)."
    return 0
  fi

  start_gateway
  wait_for_health
}

main "$@"
