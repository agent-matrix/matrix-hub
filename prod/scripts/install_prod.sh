#!/usr/bin/env bash
set -euo pipefail

# === Matrix Hub Production Installer ===
# Detects Ubuntu version and runs the right setup script.
# Supports Ubuntu 20.04 and 22.04.

detect_ubuntu_version() {
  lsb_release -rs 2>/dev/null || echo "unknown"
}

install_docker() {
  case "$1" in
    20.04)
      echo "==> Running setup_docker_ubuntu2004.sh"
      curl -fsSLo setup_docker_ubuntu2004.sh \
        https://raw.githubusercontent.com/agent-matrix/matrix-hub/master/prod/scripts/setup_docker_ubuntu2004.sh
      chmod +x setup_docker_ubuntu2004.sh
      ./setup_docker_ubuntu2004.sh
      ;;
    22.04)
      echo "==> Running setup_docker_ubuntu2204.sh"
      curl -fsSLo setup_docker_ubuntu2204.sh \
        https://raw.githubusercontent.com/agent-matrix/matrix-hub/master/prod/scripts/setup_docker_ubuntu2204.sh
      chmod +x setup_docker_ubuntu2204.sh
      ./setup_docker_ubuntu2204.sh
      ;;
    *)
      echo "ERROR: Unsupported Ubuntu version: $1"
      exit 1
      ;;
  esac
}

main() {
  echo "==> Detecting Ubuntu version..."
  version="$(detect_ubuntu_version)"

  install_docker "$version"

  echo
  echo "==> Downloading deployment script"
  curl -fsSLo deploy_matrix_hub.sh \
    https://raw.githubusercontent.com/agent-matrix/matrix-hub/master/prod/scripts/deploy_matrix_hub.sh
  chmod +x deploy_matrix_hub.sh

  echo
  echo "================================================================================"
  echo "✅ Setup complete on Ubuntu $version"
  echo "================================================================================"
  echo

  if docker info >/dev/null 2>&1; then
    echo "✅ Docker is usable by the current shell. Proceeding with deployment..."
    ./deploy_matrix_hub.sh
  else
    echo "⚠️  Docker group membership requires re-login."
    echo "Please log out and log back in, then run:"
    echo "   ./deploy_matrix_hub.sh"
  fi
}

main "$@"
