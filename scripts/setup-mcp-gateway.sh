#!/usr/bin/env bash
# 1-Setup-MCP-Gateway.sh
set -euo pipefail

BASE_DIR="$(pwd)"
PROJECT_DIR="${BASE_DIR}/mcpgateway"
VENV_DIR="${PROJECT_DIR}/.venv"

# 1) OS check (Ubuntu 22.04 hint)
if ! grep -q "22.04" /etc/os-release 2>/dev/null; then
  echo "⚠️  This script targets Ubuntu 22.04; it may work elsewhere with minor changes."
fi

# 2) OS deps
echo "⏳ Updating package lists…"
sudo apt-get update -y
echo "⏳ Installing prerequisites…"
sudo apt-get install -y git curl jq unzip iproute2 \
  python3 python3-venv python3-dev build-essential libffi-dev libssl-dev

# 3) Clone / update repo
if [ ! -d "${PROJECT_DIR}/.git" ]; then
  echo "⏳ Cloning IBM/mcp-context-forge into ${PROJECT_DIR}…"
  git clone https://github.com/IBM/mcp-context-forge.git "${PROJECT_DIR}"
else
  echo "🔄 Repo exists; updating…"
  pushd "${PROJECT_DIR}" >/dev/null
    git fetch --all --prune
    git pull --ff-only
  popd >/devnull || popd >/dev/null || true
fi

# 4) venv
if [ -d "${VENV_DIR}" ]; then
  read -r -p "⚠️  Virtualenv exists at ${VENV_DIR}. Recreate it? [y/N] " resp
  if [[ "${resp,,}" == "y" ]]; then
    rm -rf "${VENV_DIR}"
    python3 -m venv "${VENV_DIR}"
  else
    echo "✅ Reusing venv."
  fi
else
  echo "⏳ Creating venv at ${VENV_DIR}…"
  python3 -m venv "${VENV_DIR}"
fi

# 5) Activate & install
# shellcheck disable=SC1090
source "${VENV_DIR}/bin/activate"
pip install --upgrade pip setuptools wheel

pushd "${PROJECT_DIR}" >/dev/null
  if [ -f "pyproject.toml" ]; then
    echo "⏳ Installing project (editable)…"
    pip install -e '.[dev]' || pip install -e .
  elif [ -f "requirements.txt" ]; then
    pip install -r requirements.txt
  fi
  if [ -f ".env.example" ] && [ ! -f ".env" ]; then
    cp .env.example .env
    echo "✅ Created ${PROJECT_DIR}/.env from example. Review before starting."
  fi
popd >/dev/null

echo
echo "🎉 Setup complete."
echo "Next:"
echo "  - Edit ${PROJECT_DIR}/.env (credentials, port)."
echo "  - Run: scripts/2-Start-MCP-Gateway.sh"
