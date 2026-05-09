#!/usr/bin/env bash
#
# scripts/install_docker_ubuntu.sh
#
# Idempotent Docker CE installer for Ubuntu (20.04 / 22.04 / 24.04).
# Mirrors https://docs.docker.com/engine/install/ubuntu/.
#
# Safe to re-run: skips work that is already done.
#
# Usage:
#   sudo bash scripts/install_docker_ubuntu.sh
#   bash scripts/install_docker_ubuntu.sh         # will prompt for sudo as needed

set -Eeuo pipefail

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# --- 0. preflight ---
[ "$(uname -s)" = "Linux" ] || die "this script only runs on Linux"
. /etc/os-release 2>/dev/null || die "/etc/os-release missing — not a standard Linux"
[ "${ID:-}" = "ubuntu" ] || warn "ID=${ID:-?} is not 'ubuntu' — proceeding anyway, but the apt repo path is Ubuntu-specific"

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null || die "not root and 'sudo' not installed"
  SUDO="sudo"
fi

bold "▶ Installing Docker CE on ${PRETTY_NAME:-Ubuntu}"

# --- 1. base packages ---
$SUDO apt-get update -y
$SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg lsb-release

# --- 2. apt repo + signing key ---
KEYRING=/etc/apt/keyrings/docker.gpg
LIST=/etc/apt/sources.list.d/docker.list
ARCH="$(dpkg --print-architecture)"
CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME}")"

if [ ! -s "$KEYRING" ]; then
  $SUDO mkdir -p "$(dirname "$KEYRING")"
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | $SUDO gpg --dearmor --batch --yes -o "$KEYRING"
  $SUDO chmod a+r "$KEYRING"
  ok "installed signing key at $KEYRING"
else
  ok "signing key already present"
fi

# Always rewrite the list so codename / arch stay correct.
echo "deb [arch=${ARCH} signed-by=${KEYRING}] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
  | $SUDO tee "$LIST" >/dev/null
ok "apt source: $LIST"

$SUDO apt-get update -y

# --- 3. engine ---
if command -v docker >/dev/null 2>&1; then
  ok "docker already installed: $(docker --version)"
else
  $SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  ok "docker installed: $(docker --version)"
fi

# --- 4. enable + start ---
$SUDO systemctl enable --now docker
ok "docker.service enabled and started"

# --- 5. group membership ---
TARGET_USER="${SUDO_USER:-$USER}"
if id -nG "$TARGET_USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
  ok "$TARGET_USER already in 'docker' group"
else
  $SUDO usermod -aG docker "$TARGET_USER"
  warn "added $TARGET_USER to 'docker' group — log out and back in (or run 'newgrp docker') to use docker without sudo"
fi

# --- 6. smoke test ---
if $SUDO docker run --rm hello-world >/dev/null 2>&1; then
  ok "docker run hello-world: OK"
else
  warn "docker run hello-world failed — check 'docker info' and 'systemctl status docker'"
fi

bold "✓ Docker CE setup complete"
info "Next:"
info "  bash scripts/install_certificate.sh   # install Cloudflare Origin Cert at /etc/ssl/matrixhub"
info "  cp .env.example .env && \$EDITOR .env # configure backend env"
info "  bash scripts/bootstrap_host.sh        # full orchestrated first-time setup"
