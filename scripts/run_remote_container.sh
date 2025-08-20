#!/usr/bin/env bash
#
# scripts/run_remote_container.sh
# Pulls the remote image and runs it using the exact same environment file
# and script mounting logic as the original run_container.sh script.
#

set -Eeuo pipefail

# --- Paths & Config ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

# --- Image & Runtime Config ---
IMAGE_REPO="${IMAGE_REPO:-ruslanmv/matrix-hub}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
FULL_IMAGE_NAME="${IMAGE_REPO}:${IMAGE_TAG}"

CONTAINER_NAME="${CONTAINER_NAME:-matrix-hub-remote}"
HUB_PORT="${HUB_PORT:-7300}"
GATEWAY_PORT="${GATEWAY_PORT:-4444}"
NETWORK_NAME="${NETWORK_NAME:-matrixhub-net}"

# --- Environment File Paths (exactly as before) ---
# Hub
HUB_ENV_REAL="${PROJECT_ROOT}/.env"
HUB_ENV_EXAMPLE="${PROJECT_ROOT}/.env.example"
HUB_ENV_IN_CONTAINER="/app/.env"

# Gateway
GW_ENV_LOCAL_HOST="${PROJECT_ROOT}/.env.gateway.local"
GW_ENV_EXAMPLE_HOST="${PROJECT_ROOT}/.env.gateway.example"
GW_ENV_LOCAL_CONT="/app/.env.gateway.local"
GW_ENV_EXAMPLE_CONT="/app/.env.gateway.example"

# Start script to be mounted
HOST_START_SCRIPT="${PROJECT_ROOT}/scripts/start-mcp-gateway.sh"
CONT_START_SCRIPT="/app/scripts/start-mcp-gateway.sh"

# --- Helpers ---
step() { printf "▶️  %s\n" "$*"; }
info() { printf "ℹ️  %s\n" "$*"; }
die()  { printf "✖️  %s\n" "$*\n" >&2; exit 1; }

ensure_network() {
  if ! docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
    step "Creating network ${NETWORK_NAME}"
    docker network create "${NETWORK_NAME}" >/dev/null
  fi
}

# Select Hub env: .env, else .env.example (error if neither)
pick_hub_env() {
  if [[ -f "${HUB_ENV_REAL}" ]]; then
    HUB_ENV_HOST_PATH="${HUB_ENV_REAL}"
    info "Using Hub env: ${HUB_ENV_HOST_PATH}"
  elif [[ -f "${HUB_ENV_EXAMPLE}" ]]; then
    HUB_ENV_HOST_PATH="${HUB_ENV_EXAMPLE}"
    info "Using Hub env example: ${HUB_ENV_HOST_PATH}"
  else
    die "Neither ${HUB_ENV_REAL} nor ${HUB_ENV_EXAMPLE} found."
  fi
}

# Select Gateway env source: .env.gateway.local, else .env.gateway.example (error if neither)
pick_gateway_env_sources() {
  GW_MOUNT_OPTS=() # will hold one -v mapping to either local or example
  if [[ -f "${GW_ENV_LOCAL_HOST}" ]]; then
    GW_MOUNT_OPTS=(-v "${GW_ENV_LOCAL_HOST}:${GW_ENV_LOCAL_CONT}:ro")
    info "Using Gateway env: ${GW_ENV_LOCAL_HOST} → ${GW_ENV_LOCAL_CONT}"
  elif [[ -f "${GW_ENV_EXAMPLE_HOST}" ]]; then
    GW_MOUNT_OPTS=(-v "${GW_ENV_EXAMPLE_HOST}:${GW_ENV_EXAMPLE_CONT}:ro")
    info "Using Gateway env example: ${GW_ENV_EXAMPLE_HOST} → ${GW_ENV_EXAMPLE_CONT}"
  else
    die "Neither ${GW_ENV_LOCAL_HOST} nor ${GW_ENV_EXAMPLE_HOST} found."
  fi
}

stop_rm_if_exists() {
  local name="$1"
  if [ -n "$(docker ps -q -f name="^${name}$")" ]; then
    step "Stopping existing container: ${name}"
    docker stop "${name}" >/dev/null
  fi
  if [ -n "$(docker ps -aq -f name="^${name}$")" ]; then
    step "Removing existing container: ${name}"
    docker rm "${name}" >/dev/null
  fi
}

# --- Main Execution ---
step "Pulling image: ${FULL_IMAGE_NAME}"
docker pull "${FULL_IMAGE_NAME}"

[[ -f "${HOST_START_SCRIPT}" ]] || die "Startup script not found at: ${HOST_START_SCRIPT}"

ensure_network
pick_hub_env
pick_gateway_env_sources
stop_rm_if_exists "${CONTAINER_NAME}"

step "Starting container '${CONTAINER_NAME}'..."

# This 'docker run' command is now identical to the one in the original 'run_container.sh'
docker run -d \
  --name "${CONTAINER_NAME}" \
  --network "${NETWORK_NAME}" \
  -p "${HUB_PORT}:7300" \
  -p "${GATEWAY_PORT}:4444" \
  --restart unless-stopped \
  -v "${HUB_ENV_HOST_PATH}:${HUB_ENV_IN_CONTAINER}:ro" \
  "${GW_MOUNT_OPTS[@]}" \
  -v "${HOST_START_SCRIPT}:${CONT_START_SCRIPT}:ro" \
  --entrypoint /bin/bash \
  "${FULL_IMAGE_NAME}" \
  -lc '
    set -e
    # Kick off Gateway in background using the provided start script.
    # It will look for /app/.env.gateway.local first, then /app/.env.gateway.example,
    # copy into /app/mcpgateway/.env, and handle Alembic stamping/init safely.
    bash '"${CONT_START_SCRIPT}"' &

    # Start Hub (foreground)
    exec /app/.venv/bin/gunicorn src.app:app -k uvicorn.workers.UvicornWorker --bind 0.0.0.0:7300
  '

echo
echo "✅ Container is up."
info "Logs:    docker logs -f ${CONTAINER_NAME}"
info "Hub:     http://localhost:${HUB_PORT}/"
info "Gateway: http://localhost:${GATEWAY_PORT}/"
