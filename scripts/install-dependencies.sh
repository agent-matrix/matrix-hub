#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# scripts/install-dependencies.sh
#
# Installs OS packages and Python deps for Matrix Hub development and
# MCP-Gateway runtime on Linux (Debian/Ubuntu or RHEL/Fedora families).
#
# Usage:
#   bash scripts/install-dependencies.sh
# ------------------------------------------------------------------------------

set -Eeuo pipefail

have_cmd() { command -v "$1" >/dev/null 2>&1; }

if have_cmd apt-get; then
  echo "⏳ Installing with apt-get (Debian/Ubuntu)…"
  sudo apt-get update -y
  sudo apt-get install -y \
    git curl jq unzip ca-certificates \
    python3 python3-venv python3-dev build-essential \
    libffi-dev libssl-dev \
    iproute2 \
    # Optional for docs & sqlite dev headers
    sqlite3 libsqlite3-dev
elif have_cmd dnf; then
  echo "⏳ Installing with dnf (RHEL/Fedora)…"
  sudo dnf install -y \
    git curl jq unzip ca-certificates \
    python3 python3-venv python3-devel @development-tools \
    libffi-devel openssl-devel \
    iproute \
    sqlite
else
  echo "⚠️  Unknown package manager. Please install:"
  echo "    git curl jq unzip python3 python3-venv python3-dev build-essential libffi-dev libssl-dev iproute2 sqlite3 libsqlite3-dev"
fi

# Optional: Docker CLI if you plan to run gateway or hub via containers
if have_cmd apt-get; then
  echo "⏳ Installing Docker CLI (optional)…"
  sudo apt-get install -y docker.io docker-compose-plugin || true
elif have_cmd dnf; then
  echo "⏳ Installing Docker (optional)…"
  sudo dnf install -y docker docker-compose || true
fi

# Python venv bootstrap for Matrix Hub (edit as you prefer)
VENV_DIR="${VENV_DIR:-.venv}"
if [[ ! -d "${VENV_DIR}" ]]; then
  echo "⏳ Creating venv at ${VENV_DIR}…"
  python3 -m venv "${VENV_DIR}"
fi
# shellcheck disable=SC1090
source "${VENV_DIR}/bin/activate"
pip install --upgrade pip setuptools wheel

echo "📦 Installing Matrix Hub (dev extras)…"
pip install -e '.[dev]' || true

echo "✅ Dependencies installed."
echo "   • Activate venv:  source ${VENV_DIR}/bin/activate"
echo "   • Run API dev:    make dev"
