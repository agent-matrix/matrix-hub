#!/usr/bin/env bash
#
# run.sh - Unified Installer & Launcher for MCP-Gateway
#
# This script provides a one-shot, production-ready workflow to set up and
# run the MCP Gateway. It is idempotent and suitable for CI/CD environments.
#
# Features:
# - Parses command-line arguments for custom configuration.
# - Installs OS dependencies for macOS, Debian/Ubuntu, and RHEL/Fedora.
# - Installs Python 3.11 if not present (via external script on Linux).
# - Clones or updates the MCP Gateway git repository.
# - Creates a Python virtual environment and installs dependencies.
# - Generates a secure, default .env file if one doesn't exist.
# - Initializes the database.
# - Starts the gateway as a background process, logging to a file.
# - Waits for the health check endpoint to confirm the server is running.
#
# Usage:
#   ./run.sh [--project-dir ./mcpgateway] [--branch main] [--force] [--non-interactive]
#

set -Eeuo pipefail

# --- Defaults & Flags ---
PROJECT_DIR_NAME="mcpgateway"
BRANCH="v0.4.0"
HOST="0.0.0.0"
PORT="4444"
NON_INTERACTIVE="false"
FORCE="false"

# --- Dynamic Paths ---
# The absolute path to the directory containing this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The root directory of the entire project (one level up from 'scripts')
BASE_DIR="$(dirname "${SCRIPT_DIR}")"
# The final, absolute path to the mcpgateway project directory
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
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done


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
  elif have_cmd dnf; then
    log "🐧 RHEL/Fedora detected. Installing packages..."
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
    log "🗑  Removing existing virtual environment (as per --force flag)..."
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
  mkdir -p "${LOG_DIR}"
  if [[ -f "${ENV_FILE}" ]]; then
    log "✅ Using existing .env file: ${ENV_FILE}"
    return
  fi

  log "⏳ No .env file found. Creating one with secure, random defaults..."
  RAND_PASS="$(openssl rand -hex 16)"
  RAND_JWT="$(openssl rand -hex 24)"
  cat > "${ENV_FILE}" <<EOF
# --- MCP Gateway .env (autogenerated by run.sh) ---
HOST=${HOST}
PORT=${PORT}
BASIC_AUTH_USERNAME=admin
BASIC_AUTH_PASSWORD=${RAND_PASS}
JWT_SECRET_KEY=${RAND_JWT}
DATABASE_URL=sqlite:///./gateway.sqlite
LOG_LEVEL=INFO
EOF
  log "✅ Wrote new configuration to ${ENV_FILE}."
  log "ℹ️  Default username is 'admin', with a randomly generated password."
}


# =============================================================================
# PHASE 3: EXECUTION
# =============================================================================
log "### PHASE 3: GATEWAY EXECUTION ###"

# --- 3.1 Initialize Database ---
init_db() {
  # shellcheck disable=SC1090
  source "${VENV_DIR}/bin/activate"
  pushd "${PROJECT_DIR}" >/dev/null
    log "⏳ Initializing gateway database..."
    python -m mcpgateway.db
  popd >/dev/null
  log "✅ Database initialized."
}

# --- 3.2 Start Gateway ---
start_gateway() {
  if lsof -iTCP:"${PORT}" -sTCP:LISTEN -t >/dev/null; then
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

# --- 3.3 Wait for Health Check ---
wait_for_health() {
  local url="http://127.0.0.1:${PORT}/health"
  log "⏳ Waiting for gateway to become healthy at ${url}..."
  for i in {1..30}; do
    if curl -fsS "${url}" >/dev/null 2>&1; then
      local admin_url="http://localhost:${PORT}/admin/"
      log "🎉 Gateway is healthy and running!"
      log "➡️ Admin UI available at: ${admin_url}"
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
  start_gateway
  wait_for_health
}

main "$@"