#!/usr/bin/env bash
#
# scripts/stop_container.sh
# Stops and removes the production Docker container.
#

set -Eeuo pipefail

# --- Configuration ---
# This must match the name used in run_container.sh
CONTAINER_NAME="${CONTAINER_NAME:-matrixhub}"

# --- Main Stop Logic ---

# Check if the container is running and stop it.
if [ "$(docker ps -q -f name="^/${CONTAINER_NAME}$")" ]; then
    echo "▶️ Stopping container '${CONTAINER_NAME}'..."
    docker stop "${CONTAINER_NAME}"
else
    echo "ℹ️ Container '${CONTAINER_NAME}' is not running."
fi

# Check if the container exists (even if stopped) and remove it.
if [ "$(docker ps -aq -f name="^/${CONTAINER_NAME}$")" ]; then
    echo "▶️ Removing container '${CONTAINER_NAME}'..."
    docker rm "${CONTAINER_NAME}"
    echo "✅ Container stopped and removed successfully."
else
    echo "ℹ️ No container named '${CONTAINER_NAME}' found to remove."
fi
