#!/usr/bin/env bash
#
# scripts/build_container_prod.sh
# Build a production-grade Docker image using Dockerfile (prod-ready) and tag it.
#
# Usage:
#   ./scripts/build_container_prod.sh                # uses defaults
#   IMAGE_NAME=my-hub IMAGE_TAG=latest ./scripts/build_container_prod.sh
#   DOCKERFILE=Dockerfile.prod ./scripts/build_container_prod.sh
#
set -Eeuo pipefail

# --- Resolve project paths ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

# --- Configurable knobs (overridable via env) ---
IMAGE_NAME="${IMAGE_NAME:-matrixhub}"
# If not on a git repo, fall back to "local"
GIT_SHA="$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || echo local)"
IMAGE_TAG="${IMAGE_TAG:-$(date +%Y%m%d)-${GIT_SHA}}"
FULL_IMAGE_NAME="${IMAGE_NAME}:${IMAGE_TAG}"
# Allow choosing an alternate Dockerfile (e.g., Dockerfile.prod)
DOCKERFILE_PATH="${DOCKERFILE:-${PROJECT_ROOT}/Dockerfile}"

# Optional build args (pass-through)
BUILD_ARGS=()
[[ -n "${PIP_INDEX_URL:-}" ]] && BUILD_ARGS+=("--build-arg" "PIP_INDEX_URL=${PIP_INDEX_URL}")

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
  docker build -t "${FULL_IMAGE_NAME}" -f "${DOCKERFILE_PATH}" "${BUILD_ARGS[@]}" .
)

echo
echo "✅ Successfully built: ${FULL_IMAGE_NAME}"

# Helpful next steps
cat <<EOF

Run API only (no scheduler):
  docker run -d --name hub-api \
    -e INGEST_SCHED_ENABLED=false \
    -e DATABASE_URL=postgresql+psycopg://matrix:matrix@localhost:5432/matrixhub \
    -p 7300:7300 \
    ${FULL_IMAGE_NAME} \
    /app/.venv/bin/gunicorn -k uvicorn.workers.UvicornWorker -w 4 -b 0.0.0.0:7300 src.app:app

Run Worker (scheduler enabled):
  docker run -d --name hub-worker \
    -e INGEST_SCHED_ENABLED=true \
    -e DATABASE_URL=postgresql+psycopg://matrix:matrix@localhost:5432/matrixhub \
    ${FULL_IMAGE_NAME} \
    /app/.venv/bin/uvicorn src.app:app --host 0.0.0.0 --port 7301 --workers 1

Run full stack via compose (prod):
  docker compose -f docker-compose.prod.yml up -d --build

EOF
