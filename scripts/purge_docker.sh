#!/usr/bin/env bash
#
# scripts/purge_docker.sh
# Wipes all Docker containers, images, volumes, and networks.
#
# ⚠️ WARNING: This is destructive. Use only if you want a completely clean Docker state.

set -Eeuo pipefail

echo "⚠️ This will remove ALL Docker containers, images, volumes, and networks."
read -p "Are you sure? (y/N): " CONFIRM
if [[ "${CONFIRM}" != "y" && "${CONFIRM}" != "Y" ]]; then
  echo "Aborted."
  exit 0
fi

echo "▶️ Stopping all running containers..."
docker stop $(docker ps -aq) 2>/dev/null || true

echo "▶️ Removing all containers..."
docker rm -f $(docker ps -aq) 2>/dev/null || true

echo "▶️ Removing all images..."
docker rmi -f $(docker images -aq) 2>/dev/null || true

echo "▶️ Removing all volumes..."
docker volume rm -f $(docker volume ls -q) 2>/dev/null || true

echo "▶️ Removing all networks (except default)..."
docker network rm $(docker network ls | awk '/bridge|host|none/ {next} {print $1}') 2>/dev/null || true

echo "▶️ Pruning builder cache..."
docker builder prune -af 2>/dev/null || true

echo "✅ Docker environment purged. You now have a clean slate."
