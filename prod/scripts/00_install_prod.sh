#!/usr/bin/env bash
set -euo pipefail

# This helper bootstraps a production Ubuntu 20.04 host in two steps:
#  1) Install Docker + Compose plugin (run as root via sudo)
#  2) Deploy the Matrix Hub with Docker Compose (run as your normal user)
#
# It downloads 01/02 from the repo's raw URLs so you can run this script from anywhere.

BASE_RAW_URL="https://raw.githubusercontent.com/agent-matrix/matrix-hub/main/prod/scripts"

# Ensure curl is present
if ! command -v curl >/dev/null 2>&1; then
  echo "curl not found. Installing..."
  sudo apt-get update -y && sudo apt-get install -y curl
fi

echo "==> Downloading setup scripts"
curl -fsSLo 01_setup_docker_ubuntu2004.sh "${BASE_RAW_URL}/01_setup_docker_ubuntu2004.sh"
curl -fsSLo 02_deploy_matrix_hub.sh      "${BASE_RAW_URL}/02_deploy_matrix_hub.sh"
chmod +x 01_setup_docker_ubuntu2004.sh 02_deploy_matrix_hub.sh

echo
echo "==> STEP 1: Installing Docker (requires sudo)"
sudo ./01_setup_docker_ubuntu2004.sh

echo
echo "================================================================================"
echo "Docker installation complete."
echo
echo "IMPORTANT: If this is the first time you've added your user to the 'docker' group,"
echo "you MUST log out and log back in (or reboot) before running the deploy step."
echo "================================================================================"
echo

# If docker is usable without sudo right now, we can continue automatically.
if docker info >/dev/null 2>&1; then
  echo "✅ Docker is usable by the current shell. Proceeding with deployment..."
  # Default to cloning from the public repo into /opt/matrix-hub
  REPO_URL="https://github.com/agent-matrix/matrix-hub" ./02_deploy_matrix_hub.sh
else
  cat <<'INSTRUCTIONS'

Next steps (run as your normal user AFTER re-login):

# 2) Deploy your app (defaults to cloning from official repo)
REPO_URL=https://github.com/agent-matrix/matrix-hub ./02_deploy_matrix_hub.sh

# Or, if you already have the source locally:
SOURCE_DIR=/home/ubuntu/matrix-hub ./02_deploy_matrix_hub.sh

INSTRUCTIONS
fi
