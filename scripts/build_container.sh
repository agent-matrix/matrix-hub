#!/usr/bin/env bash
#
# scripts/build_container_prod.sh
# Build a production-grade Docker image using Dockerfile (prod-ready) and tag it.
#
# Usage:
#   ./scripts/build_container_prod.sh
#   IMAGE_NAME=my-hub IMAGE_TAG=latest ./scripts/build_container_prod.sh
#   DOCKERFILE=Dockerfile.prod ./scripts/build_container_prod.sh
#   GATEWAY_REF=main ./scripts/build_container_prod.sh
#

set -Eeuo pipefail

# --- Resolve project paths ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

# --- Configurable knobs (overridable via env) ---
IMAGE_NAME="${IMAGE_NAME:-matrixhub}"
GIT_SHA="$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || echo local)"
IMAGE_TAG="${IMAGE_TAG:-$(date +%Y%m%d)-${GIT_SHA}}"
FULL_IMAGE_NAME="${IMAGE_NAME}:${IMAGE_TAG}"
DOCKERFILE_PATH="${DOCKERFILE:-${PROJECT_ROOT}/Dockerfile}"

# Optional build args (pass-through)
BUILD_ARGS=()
[[ -n "${PIP_INDEX_URL:-}" ]] && BUILD_ARGS+=("--build-arg" "PIP_INDEX_URL=${PIP_INDEX_URL}")
[[ -n "${GATEWAY_REF:-}"    ]] && BUILD_ARGS+=("--build-arg" "GATEWAY_REF=${GATEWAY_REF}")

echo "▶️  Building Docker image: ${FULL_IMAGE_NAME}"
echo "📁 Context: ${PROJECT_ROOT}"
echo "🐳 Dockerfile: ${DOCKERFILE_PATH}"

# Ensure Dockerfile exists
if [[ ! -f "${DOCKERFILE_PATH}" ]]; then
  echo "❌ Dockerfile not found at: ${DOCKERFILE_PATH}" >&2
  exit 1
fi

# Build
(
  cd "${PROJECT_ROOT}" && \
  DOCKER_BUILDKIT=${DOCKER_BUILDKIT:-1} docker build \
    -t "${FULL_IMAGE_NAME}" \
    -t "${IMAGE_NAME}:latest" \
    -f "${DOCKERFILE_PATH}" \
    "${BUILD_ARGS[@]}" \
    .
)

echo
echo "✅ Successfully built:"
echo "   - ${FULL_IMAGE_NAME}"
echo "   - ${IMAGE_NAME}:latest"

cat <<'EOF'

Next:
  # Run API only (override CMD)
  docker run -d --name hub-api \
    -e INGEST_SCHED_ENABLED=false \
    -e DATABASE_URL=postgresql+psycopg://matrix:matrix@localhost:5432/matrixhub \
    -p 443:443 \
    matrixhub:latest \
    /app/.venv/bin/gunicorn -k uvicorn.workers.UvicornWorker -w 4 -b 0.0.0.0:443 src.app:app

  # Run Gateway+Hub via supervisor (default CMD). Be sure to mount a Postgres .env for the Gateway:
  #   /app/mcpgateway/.env must contain: DATABASE_URL=postgresql+psycopg://matrix:matrix@<db-host>:5432/mcpgateway
  docker run -d --name matrixhub \
    -p 443:443 -p 4444:4444 \
    -v "$PWD/.env.gateway:/app/mcpgateway/.env:ro" \
    matrixhub:latest

EOF
