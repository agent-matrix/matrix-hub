#!/usr/bin/env bash
#
# scripts/monitor_container.sh
# Follows the logs of the running production Docker container.
#

set -Eeuo pipefail

# --- Configuration ---
# This must match the name used in run_container.sh
CONTAINER_NAME="${CONTAINER_NAME:-matrix-hub-production}"

# --- Main Logic ---

echo "▶️ Following logs for container '${CONTAINER_NAME}'..."
echo "   (Press Ctrl+C to stop following)"

# Check if the container exists before trying to get logs.
if ! docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "❌ Error: Container '${CONTAINER_NAME}' not found."
    exit 1
fi

# Use 'docker logs -f' to attach to the container's log stream.
docker logs -f "${CONTAINER_NAME}"
