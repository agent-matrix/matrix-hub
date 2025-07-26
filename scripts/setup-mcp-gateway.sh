#!/usr/bin/env bash
# setup-mcp-gateway.sh
# This script sets up the MCP Gateway project by checking dependencies,
# cloning the repository, and creating a Python 3.11 virtual environment.

set -euo pipefail

# --- Configuration ---
# Get the directory of the script itself to make paths more robust
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Assume the project root is the parent directory of the 'scripts' directory
BASE_DIR="$(dirname "${SCRIPT_DIR}")"
PROJECT_DIR="${BASE_DIR}/mcpgateway"
VENV_DIR="${PROJECT_DIR}/.venv"
INSTALL_PYTHON_SCRIPT="${SCRIPT_DIR}/install_python.sh"

# 1) OS check (Informational hint for Ubuntu 22.04)
if [ -f /etc/os-release ] && ! grep -q "22.04" /etc/os-release; then
  echo "⚠️  This script is optimized for Ubuntu 22.04; it may work on other systems with minor adjustments."
fi

# 2) Check for Python 3.11 and install if it's missing
echo "⏳ Checking for Python 3.11..."
if ! command -v python3.11 &>/dev/null; then
  echo "❌ Python 3.11 not found."
  if [ -f "${INSTALL_PYTHON_SCRIPT}" ]; then
    echo "🚀 Running the Python installer script: ${INSTALL_PYTHON_SCRIPT}"
    # Ensure the installer script is executable
    chmod +x "${INSTALL_PYTHON_SCRIPT}"
    # Execute the installer
    "${INSTALL_PYTHON_SCRIPT}"
    # Verify that the installation was successful
    if ! command -v python3.11 &>/dev/null; then
        echo "❌ Installation failed. Python 3.11 is still not available. Exiting." >&2
        exit 1
    fi
    echo "✅ Python 3.11 installed successfully."
  else
    echo "❌ Python installer script not found at ${INSTALL_PYTHON_SCRIPT}. Please ensure it exists." >&2
    exit 1
  fi
else
  echo "✅ Python 3.11 is already installed."
fi

# 3) Install OS dependencies (Python packages are now handled by the installer script)
echo "⏳ Updating package lists…"
sudo apt-get update -y
echo "⏳ Installing essential OS prerequisites (git, curl, etc.)..."
sudo apt-get install -y git curl jq unzip iproute2 build-essential libffi-dev libssl-dev

# 4) Clone or update the project repository
if [ ! -d "${PROJECT_DIR}/.git" ]; then
  echo "⏳ Cloning IBM/mcp-context-forge into ${PROJECT_DIR}…"
  git clone https://github.com/IBM/mcp-context-forge.git "${PROJECT_DIR}"

  # Checkout specific commit after cloning
  pushd "${PROJECT_DIR}" >/dev/null
    git checkout 1a37247c21cbeed212cbbd525376292de43a54bb
  popd >/dev/null

else
  echo "🔄 Repository already exists; updating from origin..."
  # Use pushd/popd to change directory temporarily and safely
  pushd "${PROJECT_DIR}" >/dev/null
    git fetch --all --prune
    git pull --ff-only

    # Optional: Reset to the specific commit if needed
    git checkout 1a37247c21cbeed212cbbd525376292de43a54bb

  popd >/dev/null
fi

# 5) Create or recreate the virtual environment using Python 3.11
if [ -d "${VENV_DIR}" ]; then
  read -r -p "⚠️  Virtualenv already exists at ${VENV_DIR}. Recreate it? [y/N] " resp
  if [[ "${resp,,}" == "y" ]]; then
    echo "🗑️  Removing existing virtual environment..."
    rm -rf "${VENV_DIR}"
    echo "🐍 Creating new virtual environment with Python 3.11..."
    python3.11 -m venv "${VENV_DIR}"
  else
    echo "✅ Reusing existing virtual environment."
  fi
else
  echo "🐍 Creating new virtual environment with Python 3.11 at ${VENV_DIR}…"
  python3.11 -m venv "${VENV_DIR}"
fi

# 6) Activate the virtual environment and install project dependencies
echo "📦 Activating virtual environment and installing dependencies..."
# shellcheck disable=SC1090
source "${VENV_DIR}/bin/activate"
pip install --upgrade pip setuptools wheel

pushd "${PROJECT_DIR}" >/dev/null
  if [ -f "pyproject.toml" ]; then
    echo "⏳ Installing project in editable mode from pyproject.toml..."
    # Try to install with 'dev' extras, fall back to a standard editable install
    pip install -e '.[dev]' || pip install -e .
  elif [ -f "requirements.txt" ]; then
    echo "⏳ Installing dependencies from requirements.txt..."
    pip install -r requirements.txt
  fi

  # Copy .env.example to .env if it doesn't already exist
  if [ -f ".env.example" ] && [ ! -f ".env" ]; then
    cp .env.example .env
    echo "✅ Created ${PROJECT_DIR}/.env from example. Please review it before starting."
  fi
popd >/dev/null

echo
echo "🎉 Setup complete!"
echo "Next steps:"
echo "  - Edit the configuration in ${PROJECT_DIR}/.env (credentials, port, etc.)."
echo "  - Run the start script, e.g., 'scripts/start-mcp-gateway.sh'"
