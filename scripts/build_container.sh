#!/usr/bin/env bash
# scripts/build_container.sh
# Build the Matrix Hub container image using the multi-stage Dockerfile.
# - Creates venvs for Hub and Gateway inside the image
# - Installs hub runtime deps (or dev extras if requested)
# - Runs scripts/setup-mcp-gateway.sh (unless skipped)
# - Tags the image and prints next steps

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# ---------------------------
# Defaults (override via flags)
# ---------------------------
IMAGE_NAME="${IMAGE_NAME:-matrix-hub}"
TAG_DEFAULT="latest"
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  # Try a useful tag from git if available
  TAG_DEFAULT="$(git describe --tags --dirty --always 2>/dev/null || echo latest)"
fi
IMAGE_TAG="${IMAGE_TAG:-$TAG_DEFAULT}"

# Build args
HUB_INSTALL_TARGET="${HUB_INSTALL_TARGET:-prod}"   # prod|dev
SKIP_GATEWAY_SETUP="${SKIP_GATEWAY_SETUP:-0}"      # 0|1

# Docker options
PLATFORM="${PLATFORM:-}"                           # e.g. linux/amd64, linux/arm64
NO_CACHE="${NO_CACHE:-0}"                          # 0|1
PULL="${PULL:-0}"                                  # 0|1
BUILDX="${BUILDX:-0}"                              # 0|1 (use buildx if set)

# ---------------------------
# CLI parsing
# ---------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -i, --image NAME             Image name (default: ${IMAGE_NAME})
  -t, --tag TAG                Image tag (default: ${IMAGE_TAG})
      --dev                    Install hub dev extras (equiv HUB_INSTALL_TARGET=dev)
      --skip-gateway-setup     Do not run scripts/setup-mcp-gateway.sh (SKIP_GATEWAY_SETUP=1)
      --platform PLAT          Target platform, e.g. linux/amd64, linux/arm64
      --no-cache               Disable Docker build cache
      --pull                   Always attempt to pull newer base images
      --buildx                 Use docker buildx build
  -h, --help                   Show this help

Examples:
  $(basename "$0") --platform linux/amd64
  $(basename "$0") -i matrix-hub -t 1.0.0
  $(basename "$0") --dev --skip-gateway-setup
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--image) IMAGE_NAME="$2"; shift 2 ;;
    -t|--tag) IMAGE_TAG="$2"; shift 2 ;;
    --dev) HUB_INSTALL_TARGET="dev"; shift 1 ;;
    --skip-gateway-setup) SKIP_GATEWAY_SETUP="1"; shift 1 ;;
    --platform) PLATFORM="$2"; shift 2 ;;
    --no-cache) NO_CACHE="1"; shift 1 ;;
    --pull) PULL="1"; shift 1 ;;
    --buildx) BUILDX="1"; shift 1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

# ---------------------------
# Sanity checks
# ---------------------------
command -v docker >/dev/null 2>&1 || { echo "✖ Docker not found in PATH." >&2; exit 1; }

# ---------------------------
# Build command
# ---------------------------
BUILD_ARGS=(
  --build-arg "HUB_INSTALL_TARGET=${HUB_INSTALL_TARGET}"
  --build-arg "SKIP_GATEWAY_SETUP=${SKIP_GATEWAY_SETUP}"
  -t "${IMAGE_NAME}:${IMAGE_TAG}"
  .
)

[[ -n "${PLATFORM}" ]] && BUILD_ARGS=( --platform "${PLATFORM}" "${BUILD_ARGS[@]}" )
[[ "${NO_CACHE}" = "1" ]] && BUILD_ARGS=( --no-cache "${BUILD_ARGS[@]}" )
[[ "${PULL}" = "1" ]] && BUILD_ARGS=( --pull "${BUILD_ARGS[@]}" )

echo "▶ Building image ${IMAGE_NAME}:${IMAGE_TAG}"
echo "  HUB_INSTALL_TARGET=${HUB_INSTALL_TARGET}"
echo "  SKIP_GATEWAY_SETUP=${SKIP_GATEWAY_SETUP}"
[[ -n "${PLATFORM}" ]] && echo "  PLATFORM=${PLATFORM}"
[[ "${NO_CACHE}" = "1" ]] && echo "  (no cache)"
[[ "${PULL}" = "1" ]] && echo "  (pull latest bases)"

if [[ "${BUILDX}" = "1" ]]; then
  docker buildx build "${BUILD_ARGS[@]}"
else
  docker build "${BUILD_ARGS[@]}"
fi

echo "✔ Build complete: ${IMAGE_NAME}:${IMAGE_TAG}"
echo ""
echo "Next:"
echo "  scripts/run_container.sh --image ${IMAGE_NAME} --tag ${IMAGE_TAG}"
