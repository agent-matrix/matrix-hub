#!/usr/bin/env bash
#
# scripts/run_container.sh
# Runs the production Docker container, mapping ports for the Hub and Gateway.
#

set -Eeuo pipefail

# --- Paths for locating the env files on the host ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

HOST_ENV_LOCAL="${PROJECT_ROOT}/.env.gateway.local"
HOST_ENV_EXAMPLE="${PROJECT_ROOT}/.env.gateway.example"
CONTAINER_ENV_PATH="/app/mcpgateway/.env"

# If .env.gateway.local is missing but example exists, create it
if [ ! -f "${HOST_ENV_LOCAL}" ] && [ -f "${HOST_ENV_EXAMPLE}" ]; then
  cp "${HOST_ENV_EXAMPLE}" "${HOST_ENV_LOCAL}"
  echo "ℹ️ Created ${HOST_ENV_LOCAL} from ${HOST_ENV_EXAMPLE}. Please review and edit credentials if needed."
fi

# Prepare an optional bind-mount argument
MOUNT_ENV_ARG=()
if [ -f "${HOST_ENV_LOCAL}" ]; then
  echo "   - Mounting ${HOST_ENV_LOCAL} -> ${CONTAINER_ENV_PATH} (read-only)"
  MOUNT_ENV_ARG=( -v "${HOST_ENV_LOCAL}:${CONTAINER_ENV_PATH}:ro" )
else
  echo "⚠️ ${HOST_ENV_LOCAL} not found. Gateway will run with defaults (no mounted .env)."
fi

# --- Configuration ---
IMAGE_NAME="${IMAGE_NAME:-matrix-hub-app}"
IMAGE_TAG="${IMAGE_TAG:-$(date +%Y%m%d)-$(git rev-parse --short HEAD 2>/dev/null || echo "local")}"
FULL_IMAGE_NAME="${IMAGE_NAME}:${IMAGE_TAG}"

CONTAINER_NAME="${CONTAINER_NAME:-matrix-hub-production}"
HUB_PORT="${HUB_PORT:-7300}"
GATEWAY_PORT="${GATEWAY_PORT:-4444}"

# --- Main Run Logic ---

# Stop/remove any existing container with same name
if [ "$(docker ps -q -f name="${CONTAINER_NAME}")" ]; then
    echo "▶️ Stopping existing container named '${CONTAINER_NAME}'..."
    docker stop "${CONTAINER_NAME}"
fi
if [ "$(docker ps -aq -f status=exited -f name="${CONTAINER_NAME}")" ]; then
    echo "▶️ Removing stopped container named '${CONTAINER_NAME}'..."
    docker rm "${CONTAINER_NAME}"
fi

echo "▶️ Running container '${CONTAINER_NAME}' from image '${FULL_IMAGE_NAME}'..."
echo "   - Hub Port: ${HUB_PORT} -> 7300"
echo "   - Gateway Port: ${GATEWAY_PORT} -> 4444"

docker run \
    -d \
    --name "${CONTAINER_NAME}" \
    -p "${HUB_PORT}:7300" \
    -p "${GATEWAY_PORT}:4444" \
    --restart unless-stopped \
    "${MOUNT_ENV_ARG[@]}" \
    "${FULL_IMAGE_NAME}"

echo
echo "✅ Container is starting in the background."
echo "➡️ To see logs, run: docker logs -f ${CONTAINER_NAME}"
echo "➡️ To stop it, run: docker stop ${CONTAINER_NAME}"
