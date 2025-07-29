#!/usr/bin/env bash
#
# scripts/build_container.sh
# Builds the production Docker image for the Matrix Hub and MCP-Gateway.
#

set -Eeuo pipefail

# --- Configuration ---
# The script determines the project's root directory (the parent of 'scripts/').
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

# You can override the image name and tag via environment variables.
# Example: IMAGE_NAME="my-custom-image" IMAGE_TAG="latest" ./scripts/build_container.sh
IMAGE_NAME="${IMAGE_NAME:-matrix-hub-app}"
IMAGE_TAG="${IMAGE_TAG:-$(date +%Y%m%d)-$(git rev-parse --short HEAD 2>/dev/null || echo "local")}"
FULL_IMAGE_NAME="${IMAGE_NAME}:${IMAGE_TAG}"

# --- Main Build Logic ---
echo "▶️ Building Docker image: ${FULL_IMAGE_NAME}"
echo "▶️ Using build context: ${PROJECT_ROOT}"

# The 'docker build' command executes from the project's root directory.
# This ensures that the Dockerfile and all necessary files (like supervisord.conf) are found.
docker build -t "${FULL_IMAGE_NAME}" -f "${PROJECT_ROOT}/Dockerfile" "${PROJECT_ROOT}"

echo
echo "✅ Successfully built image: ${FULL_IMAGE_NAME}"
echo "➡️ To run it, use the command:"
echo "   docker run -d -p 7300:7300 -p 4444:4444 --name my-matrix-hub ${FULL_IMAGE_NAME}"
