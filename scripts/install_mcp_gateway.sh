#!/usr/bin/env bash
#
# run.sh - Unified Installer & Launcher for MCP-Gateway
#
# This script provides a one-shot, production-ready workflow to set up and
# run the MCP Gateway. It is idempotent and suitable for CI/CD environments.
#

set -Eeuo pipefail

# --- Defaults & Flags ---
PROJECT_DIR_NAME="mcpgateway"
BRANCH="main"
HOST="0.0.0.0"
PORT="4444"
NON_INTERACTIVE="false"
FORCE="false"

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-dir) PROJECT_DIR_NAME="$2"; shift 2 ;;
    --branch)      BRANCH="$2"; shift 2 ;;
    --host)        HOST="$2"; shift 2 ;;
    --port)        PORT="$2"; shift 2 ;;
    --force)       FORCE="true"; shift 1 ;;
    --non-interactive) NON_INTERACTIVE="true"; shift 1 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

# --- Dynamic Paths ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "${SCRIPT_DIR}")"
PROJECT_DIR="${BASE_DIR}/${PROJECT_DIR_NAME}"
VENV_DIR="${PROJECT_DIR}/.venv"
LOG_DIR="${PROJECT_DIR}/logs"
LOG_FILE="${LOG_DIR}/mcpgateway.log"
INSTALL_PYTHON_SCRIPT="${SCRIPT_DIR}/install_python.sh"


# --- Helper Functions ---
log() { printf "\n[$(date +'%F %T')] %s\n" "$*"; }
die() { printf "\nERROR: %s\n" "$*" >&2; exit 1; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }


# =============================================================================
# PHASE 1: SYSTEM & PROJECT SETUP
# =============================================================================
log "### PHASE 1: SYSTEM & PROJECT SETUP ###"

# --- 1.1 Install OS Dependencies ---
install_os_deps() {
  log "Checking OS and dependencies..."
  if [[ "$(uname)" == "Darwin" ]]; then
    log "🍏 macOS detected. Verifying required tools are installed..."
    for tool in git curl jq; do
      have_cmd "${tool}" || die "Tool '${tool}' not found. Please install it (e.g., using Homebrew: 'brew install ${tool}')."
    done
  elif have_cmd apt-get; then
    log "🐧 Debian/Ubuntu detected. Installing system packages..."
    sudo apt-get update -y
    sudo apt-get install -y git curl jq build-essential libffi-dev libssl-dev
  elif have_cmd dnf; then
    log "🐧 RHEL/Fedora detected. Installing system packages..."
    sudo dnf install -y git curl jq gcc-c++ make libffi-devel openssl-devel
  else
    die "Unsupported OS. Please install required tools manually: git, curl, jq, and Python 3.11 build dependencies."
  fi
  log "✅ OS dependencies are satisfied."
}

# --- 1.2 Install Python 3.11 ---
ensure_python() {
  log "Checking for Python 3.11..."
  if have_cmd python3.11; then
    log "✅ Python 3.11 is already installed."
    return
  fi

  log "❌ Python 3.11 not found."
  if [[ "$(uname)" == "Linux" ]] && [ -f "${INSTALL_PYTHON_SCRIPT}" ]; then
    log "🚀 Running the Python installer script for Linux..."
    chmod +x "${INSTALL_PYTHON_SCRIPT}"
    "${INSTALL_PYTHON_SCRIPT}"
    have_cmd python3.11 || die "Python 3.11 installation failed."
  else
    die "Please install Python 3.11 manually. On macOS, use 'brew install python@3.11'."
  fi
  log "✅ Python 3.11 installed successfully."
}

# --- 1.3 Fetch Git Repository ---
fetch_repo() {
  if [[ -d "${PROJECT_DIR}/.git" ]]; then
    log "🔄 Git repository already exists at ${PROJECT_DIR}."
  else
    log "⏳ Cloning IBM/mcp-context-forge (branch: ${BRANCH}) into ${PROJECT_DIR}..."
    git clone --branch "${BRANCH}" --depth 1 https://github.com/IBM/mcp-context-forge.git "${PROJECT_DIR}"
  fi
}

# --- 1.4 Setup Python Virtual Environment ---
setup_venv() {
  if [[ -d "${VENV_DIR}" && "${FORCE}" == "true" ]]; then
    log "🗑️ Removing existing virtual environment (as per --force flag)..."
    rm -rf "${VENV_DIR}"
  fi

  if [[ ! -d "${VENV_DIR}" ]]; then
    log "🐍 Creating Python 3.11 virtual environment at ${VENV_DIR}..."
    python3.11 -m venv "${VENV_DIR}"
  fi

  log "📦 Activating virtual environment and installing dependencies..."
  # shellcheck disable=SC1090
  source "${VENV_DIR}/bin/activate"
  pip install --upgrade pip setuptools wheel >/dev/null
  pushd "${PROJECT_DIR}" >/dev/null
    pip install -e '.[dev]' || pip install -e .
  popd >/dev/null
  log "✅ Python dependencies are installed."
}


# =============================================================================
# PHASE 2: CONFIGURATION
# =============================================================================
log "### PHASE 2: CONFIGURATION ###"

ensure_env_file() {
  local ENV_SOURCE_LOCAL="${BASE_DIR}/.env.gateway.local"
  local ENV_SOURCE_EXAMPLE="${BASE_DIR}/.env.gateway.example"
  local ENV_DESTINATION="${PROJECT_DIR}/.env"

  if [ ! -f "${ENV_SOURCE_LOCAL}" ]; then
      log "ℹ️ No .env.gateway.local found in project root."
      if [ -f "${ENV_SOURCE_EXAMPLE}" ]; then
          log "ℹ️ Copying from ${ENV_SOURCE_EXAMPLE} to create a local config..."
          cp "${ENV_SOURCE_EXAMPLE}" "${ENV_SOURCE_LOCAL}"
          log "⚠️ WARNING: Created ${ENV_SOURCE_LOCAL} using default example values. You should edit this file with your actual credentials."
      else
          die "No .env.gateway.local or .env.gateway.example found in project root. Cannot continue."
      fi
  fi

  log "✅ Using config from ${ENV_SOURCE_LOCAL}."
  log "ℹ️ Copying to ${ENV_DESTINATION} for the application to use."
  cp "${ENV_SOURCE_LOCAL}" "${ENV_DESTINATION}"
  log "✅ Configuration file is ready."
}


# =============================================================================
# MAIN EXECUTION
# =============================================================================
main() {
  # --- Run Setup and Config Phases ---
  install_os_deps
  ensure_python
  fetch_repo
  setup_venv
  ensure_env_file

  # --- PHASE 3: GATEWAY EXECUTION (Using user-provided explicit logic) ---
  log "### PHASE 3: GATEWAY EXECUTION ###"

  # Activate Python venv
  # shellcheck disable=SC1090
  source "${VENV_DIR}/bin/activate"
  log "✅ Environment activated."

  # Load environment variables
  set -o allexport
  # shellcheck disable=SC1090
  source "${PROJECT_DIR}/.env"
  set +o allexport
  log "✅ Loaded environment variables."

  # Check port availability
  local current_host="${HOST:-0.0.0.0}"
  local current_port="${PORT:-4444}"
  if lsof -iTCP:"${current_port}" -sTCP:LISTEN -t >/dev/null; then
    if [[ "${NON_INTERACTIVE}" == "true" || "${FORCE}" == "true" ]]; then
        log "⚠️ Port ${current_port} is in use. Stopping existing process..."
        lsof -iTCP:"${current_port}" -sTCP:LISTEN -t | xargs kill -9
        sleep 1
    else
        read -r -p "⚠️ Port ${current_port} is in use. Stop the existing process and continue? [y/N] " r
        if [[ "${r,,}" != "y" ]]; then
            die "Port conflict; aborting."
        fi
        lsof -iTCP:"${current_port}" -sTCP:LISTEN -t | xargs kill -9
        sleep 1
    fi
  fi

  # Change into project directory
  cd "${PROJECT_DIR}"

  # Initialize database
  log "⏳ Initializing gateway database..."
  if ! python -m mcpgateway.db; then
      die "Database initialization failed. Please check the error above."
  fi
  log "✅ Database initialized successfully."

  # Create log directory to prevent errors
  mkdir -p "${LOG_DIR}"

  # Start the MCP Gateway
  local auth_user="${BASIC_AUTH_USERNAME:-admin}"
  log "▶️ Starting MCP Gateway on ${current_host}:${current_port} with user '${auth_user}'..."
  nohup mcpgateway --host "${current_host}" --port "${current_port}" > "${LOG_FILE}" 2>&1 &
  local gateway_pid=$!
  echo "${gateway_pid}" > "${PROJECT_DIR}/mcpgateway.pid"
  log "✅ MCP Gateway started (PID: ${gateway_pid}). Logs are at ${LOG_FILE}"

  # Wait for Health Check
  local health_url="http://127.0.0.1:${current_port}/health"
  log "⏳ Waiting for gateway to become healthy at ${health_url}..."
  for i in {1..30}; do
    if curl -fsS "${health_url}" >/dev/null 2>&1; then
      local admin_url="http://localhost:${current_port}/admin/"
      log "🎉 Gateway is healthy and running!"
      log "➡️ Admin UI available at: ${admin_url}"
      exit 0
    fi
    sleep 2
  done
  die "Gateway did not become healthy in time. Check logs: tail -f ${LOG_FILE}"
}

main "$@"