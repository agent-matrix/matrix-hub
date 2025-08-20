#!/usr/bin/env bash
set -euo pipefail

# ===== Config =====
CONFIGURE_UFW="${CONFIGURE_UFW:-true}"   # set to "false" to skip UFW setup

# ===== Sanity checks =====
if ! grep -q "Ubuntu 20.04" /etc/os-release; then
  echo "This script is intended for Ubuntu 20.04 (focal)." >&2
  echo "Detected:"; grep PRETTY_NAME /etc/os-release || true
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo $0" >&2
  exit 1
fi

INVOCING_USER="${SUDO_USER:-$USER}"

echo "==> Installing prerequisites"
apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release ufw openssl

echo "==> Adding Docker’s official GPG key"
install -m 0755 -d /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
fi

echo "==> Adding Docker apt repository"
ARCH="$(dpkg --print-architecture)"
echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu focal stable" \
  > /etc/apt/sources.list.d/docker.list

echo "==> Installing Docker Engine and Compose plugin"
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "==> Enabling Docker at boot"
systemctl enable --now docker

echo "==> Adding '${INVOCING_USER}' to docker group (you must re-login for this to apply)"
groupadd -f docker
usermod -aG docker "${INVOCING_USER}"

# Optional: simple firewall
if [[ "${CONFIGURE_UFW}" == "true" ]]; then
  echo "==> Configuring UFW (allow 22,80,443)"
  ufw allow 22/tcp || true
  ufw allow 80/tcp || true
  ufw allow 443/tcp || true
  ufw --force enable || true
fi

echo "==> Versions"
docker --version
docker compose version

echo "✅ Docker is installed. Log out and back in so '${INVOCING_USER}' can use Docker without sudo."
