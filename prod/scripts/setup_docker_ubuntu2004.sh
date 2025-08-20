#!/usr/bin/env bash
set -euo pipefail

# === Docker + Compose Setup for Ubuntu 20.04 ===

echo "==> STEP 1: Installing prerequisites"
sudo apt-get update -y
sudo apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    software-properties-common \
    gnupg \
    lsb-release

echo "==> STEP 2: Adding Docker’s official GPG key"
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -

echo "==> STEP 3: Setting up Docker repository"
sudo add-apt-repository \
   "deb [arch=$(dpkg --print-architecture)] https://download.docker.com/linux/ubuntu \
   $(lsb_release -cs) stable"

echo "==> STEP 4: Installing Docker Engine and Compose plugin"
sudo apt-get update -y
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin git openssl

echo "==> STEP 5: Adding current user to docker group"
sudo usermod -aG docker "$USER"

echo
echo "================================================================================"
echo "✅ Docker installation complete on Ubuntu 20.04"
echo
echo "IMPORTANT: If this is the first time you've added your user to the 'docker' group,"
echo "you MUST log out and log back in (or reboot) before running the deploy step."
echo "================================================================================"
