#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# scripts/install-dependencies.sh
#
# Installs OS packages and Python 3.11 for production workflows.
# This script is designed to be idempotent and non-interactive.
#
# Usage:
#   bash scripts/install-dependencies.sh
# ------------------------------------------------------------------------------

set -Eeuo pipefail

# Helper function to check if a command exists
have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# --- OS Dependency Installation ---
# Detects the package manager and installs required packages.

if have_cmd apt-get; then
    echo "--- Installing dependencies with apt-get (Debian/Ubuntu) ---"
    sudo apt-get update -y
    # Install common tools first
    sudo apt-get install -y \
        git curl jq unzip ca-certificates \
        build-essential libffi-dev libssl-dev \
        iproute2 sqlite3 libsqlite3-dev

    # Check for Python 3.11 and install it only if it's missing
    if ! have_cmd python3.11; then
        echo "🐍 Python 3.11 not found. Installing..."
        sudo apt-get install -y software-properties-common
        sudo add-apt-repository -y ppa:deadsnakes/ppa
        sudo apt-get update -y
        sudo apt-get install -y python3.11 python3.11-venv python3.11-dev
    else
        echo "✅ Python 3.11 is already installed."
    fi

elif have_cmd dnf; then
    echo "--- Installing dependencies with dnf (RHEL/Fedora) ---"
    # Install common tools first
    sudo dnf install -y \
        git curl jq unzip ca-certificates \
        @development-tools libffi-devel openssl-devel \
        iproute sqlite

    # Check for Python 3.11 and install it only if it's missing
    if ! have_cmd python3.11; then
        echo "🐍 Python 3.11 not found. Installing..."
        sudo dnf install -y python3.11 python3.11-devel
    else
        echo "✅ Python 3.11 is already installed."
    fi

else
    echo "❌ Unknown or unsupported package manager." >&2
    echo "   Please manually install: git, curl, jq, unzip, and Python 3.11." >&2
    exit 1
fi

# --- Optional: Docker Installation (for CI/CD environments) ---
# This section is non-critical and will not fail the script if Docker installation has issues.
if have_cmd apt-get; then
    if ! have_cmd docker; then
        echo "--- Installing Docker (optional) ---"
        # Check for conflicting packages before proceeding
        if dpkg -l | grep -q 'containerd' && ! dpkg -l | grep -q 'containerd\.io'; then
            echo "⚠️  A conflicting 'containerd' package is installed. Skipping Docker installation."
            echo "   Please manage Docker installation manually if required."
        else
            sudo apt-get install -y docker.io docker-compose-plugin || echo "⚠️  Docker installation failed, continuing script."
        fi
    else
        echo "✅ Docker is already installed."
    fi
fi


# --- Python Virtual Environment Setup ---
echo "--- Setting up Python virtual environment ---"
VENV_DIR="${VENV_DIR:-.venv}"
if [[ ! -d "${VENV_DIR}" ]]; then
    echo "🐍 Creating virtual environment with Python 3.11 at ${VENV_DIR}…"
    python3.11 -m venv "${VENV_DIR}"
fi

# Activate the venv and install project-specific python packages
# shellcheck disable=SC1090
source "${VENV_DIR}/bin/activate"

# Ensure pip exists in the new venv, which fixes potential ModuleNotFoundError
if ! have_cmd pip; then
    echo "❌ pip not found in venv. Attempting to bootstrap it..."
    python -m ensurepip --upgrade
    if ! have_cmd pip; then
        echo "❌ Failed to install pip in the virtual environment. Please check your Python 3.11 installation." >&2
        exit 1
    fi
fi

echo "📦 Upgrading pip, setuptools, and wheel..."
pip install --upgrade pip setuptools wheel

echo "📦 Installing project dependencies for production..."
# For production, install from pyproject.toml without dev extras or editable mode.
# This assumes the script is run from the project root.
pip install .

#echo
echo "✅ Dependencies installed successfully."
echo "   To use the environment, run: source ${VENV_DIR}/bin/activate"
