#!/usr/bin/env bash
# scripts/run_container.sh
# Run the Matrix Hub container built from the Dockerfile.
# - Exposes hub port (default 7300) and gateway port (default 4444) from the container
# - Mounts a persistent data volume for /app/data
# - Optionally skips the embedded gateway and uses an external one
# - Loads a .env (if present) so you control config at runtime
# - Waits for Hub health and prints helpful URLs

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# ---------------------------
# Defaults (override via flags/env)
# ---------------------------
IMAGE_NAME="${IMAGE_NAME:-matrix-hub}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
CONTAINER_NAME="${CONTAINER_NAME:-matrix-hub}"

# Host port mappings
APP_HOST_PORT="${APP_HOST_PORT:-7300}"   # host -> container 7300
GW_HOST_PORT="${GW_HOST_PORT:-4444}"     # host -> container 4444 (if gateway enabled)

# Volumes
DATA_VOLUME="${DATA_VOLUME:-matrixhub_data}"       # mounts at /app/data
GW_VOLUME="${GW_VOLUME:-}"                          # optional; mounts at /app/mcpgateway/.state

# Networking
NETWORK_NAME="${NETWORK_NAME:-}"                    # optional pre-created network
RESTART_POLICY="${RESTART_POLICY:-unless-stopped}"
DETACH="${DETACH:-1}"                               # 1=run -d, 0=foreground

# Runtime env
ENV_FILE="${ENV_FILE:-.env}"                        # will be used as --env-file if exists
GW_SKIP="${GW_SKIP:-0}"                             # 1 to skip embedded gateway (set GATEWAY_SKIP_START=1)
PULL_RUNTIME="${PULL_RUNTIME:-0}"                   # docker pull before run
REPLACE="${REPLACE:-1}"                             # stop & rm existing container if present

# ---------------------------
# CLI parsing
# ---------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -i, --image NAME               Image name (default: ${IMAGE_NAME})
  -t, --tag TAG                  Image tag (default: ${IMAGE_TAG})
  -n, --name NAME                Container name (default: ${CONTAINER_NAME})

  --app-port PORT                Map host PORT -> container 7300 (default: ${APP_HOST_PORT})
  --gw-port PORT                 Map host PORT -> container 4444 (default: ${GW_HOST_PORT})
  --skip-gateway                 Do not run embedded gateway in the container (sets GATEWAY_SKIP_START=1)
  --env-file PATH                Use a .env file for runtime (default: ${ENV_FILE})

  --data-volume NAME             Named volume for /app/data (default: ${DATA_VOLUME})
  --gw-volume NAME               Named volume for /app/mcpgateway/.state (optional; see notes)

  --network NAME                 Attach container to existing Docker network NAME
  --restart POLICY               Restart policy (default: ${RESTART_POLICY})

  -d, --detach                   Run container in background (default)
  -f, --foreground               Run container in foreground
  --pull                         docker pull image before run
  --no-replace                   Do not stop/remove existing container of same name (error instead)

  -h, --help                     Show this help

Notes:
- If you provide --gw-volume, consider setting the gateway DATABASE_URL to a file in that mount, e.g.:
    DATABASE_URL=sqlite:////app/mcpgateway/.state/mcp.db
  in your gateway env (copied to /app/mcpgateway/.env by your build or passed via --env-file).

Examples:
  $(basename "$0") --image matrix-hub --tag latest
  $(basename "$0") --skip-gateway --app-port 7310 --env-file ./.env
  $(basename "$0") --gw-volume mcpgw_data --gw-port 4445
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--image) IMAGE_NAME="$2"; shift 2 ;;
    -t|--tag) IMAGE_TAG="$2"; shift 2 ;;
    -n|--name) CONTAINER_NAME="$2"; shift 2 ;;
    --app-port) APP_HOST_PORT="$2"; shift 2 ;;
    --gw-port) GW_HOST_PORT="$2"; shift 2 ;;
    --skip-gateway) GW_SKIP="1"; shift 1 ;;
    --env-file) ENV_FILE="$2"; shift 2 ;;
    --data-volume) DATA_VOLUME="$2"; shift 2 ;;
    --gw-volume) GW_VOLUME="$2"; shift 2 ;;
    --network) NETWORK_NAME="$2"; shift 2 ;;
    --restart) RESTART_POLICY="$2"; shift 2 ;;
    -d|--detach) DETACH="1"; shift 1 ;;
    -f|--foreground) DETACH="0"; shift 1 ;;
    --pull) PULL_RUNTIME="1"; shift 1 ;;
    --no-replace) REPLACE="0"; shift 1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

# ---------------------------
# Helpers
# ---------------------------
log()  { printf "▶ %s\n" "$*"; }
warn() { printf "⚠ %s\n" "$*" >&2; }
err()  { printf "✖ %s\n" "$*" >&2; exit 1; }

has_cmd() { command -v "$1" >/dev/null 2>&1; }

port_in_use() {
  local port="$1"
  if has_cmd lsof; then
    lsof -nP -i :"${port}" | grep LISTEN >/dev/null 2>&1
  elif has_cmd netstat; then
    netstat -an 2>/dev/null | grep -E "[:\.]${port}[^0-9]" | grep LISTEN >/dev/null 2>&1
  else
    # best effort (may be blocked by firewall)
    (echo >/dev/tcp/127.0.0.1/"${port}") >/dev/null 2>&1
  fi
}

wait_for_hub() {
  local port="$1" timeout="${2:-60}" waited=0
  while ! curl -fsS "http://127.0.0.1:${port}/" >/dev/null 2>&1; do
    sleep 1
    waited=$((waited+1))
    if [[ "${waited}" -ge "${timeout}" ]]; then
      return 1
    fi
  done
  return 0
}

# ---------------------------
# Sanity checks
# ---------------------------
command -v docker >/dev/null 2>&1 || err "Docker not found in PATH."
if port_in_use "${APP_HOST_PORT}"; then
  err "Host port ${APP_HOST_PORT} is already in use. Choose another with --app-port."
fi
if [[ "${GW_SKIP}" != "1" ]] && port_in_use "${GW_HOST_PORT}"; then
  err "Host port ${GW_HOST_PORT} is already in use. Choose another with --gw-port, or use --skip-gateway."
fi

# If a container with this name exists and REPLACE=1, remove it
if docker ps -a --format '{{.Names}}' | grep -xq "${CONTAINER_NAME}"; then
  if [[ "${REPLACE}" = "1" ]]; then
    log "Removing existing container ${CONTAINER_NAME}..."
    docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  else
    err "Container ${CONTAINER_NAME} already exists. Use --no-replace to keep it or change --name."
  fi
fi

# Pull image if asked
if [[ "${PULL_RUNTIME}" = "1" ]]; then
  log "Pulling image ${IMAGE_NAME}:${IMAGE_TAG}..."
  docker pull "${IMAGE_NAME}:${IMAGE_TAG}"
fi

# Ensure a .env exists (useful for first run; scripts/run_prod.sh also guards this inside the container)
if [[ ! -f "${ENV_FILE}" && -f ".env.example" ]]; then
  cp ".env.example" "${ENV_FILE}"
  log "Created ${ENV_FILE} from .env.example"
fi

# ---------------------------
# Build docker run command
# ---------------------------
RUN_ARGS=(
  --name "${CONTAINER_NAME}"
  --restart "${RESTART_POLICY}"
)

# Ports
RUN_ARGS+=( -p "${APP_HOST_PORT}:7300" )
if [[ "${GW_SKIP}" != "1" ]]; then
  RUN_ARGS+=( -p "${GW_HOST_PORT}:4444" )
fi

# Network (optional)
[[ -n "${NETWORK_NAME}" ]] && RUN_ARGS+=( --network "${NETWORK_NAME}" )

# Volumes
RUN_ARGS+=( -v "${DATA_VOLUME}:/app/data" )
if [[ -n "${GW_VOLUME}" ]]; then
  RUN_ARGS+=( -v "${GW_VOLUME}:/app/mcpgateway/.state" )
  warn "If you mounted --gw-volume, ensure gateway DATABASE_URL points to /app/mcpgateway/.state/mcp.db in its env."
fi

# Env file (runtime)
[[ -f "${ENV_FILE}" ]] && RUN_ARGS+=( --env-file "${ENV_FILE}" )

# Skip gateway if requested
if [[ "${GW_SKIP}" = "1" ]]; then
  RUN_ARGS+=( -e "GATEWAY_SKIP_START=1" )
  log "Embedded gateway will be skipped (GATEWAY_SKIP_START=1). Ensure MCP_GATEWAY_URL points to your external gateway."
fi

# Detach / foreground
if [[ "${DETACH}" = "1" ]]; then
  RUN_ARGS+=( -d )
fi

# ---------------------------
# Run
# ---------------------------
log "Starting container ${CONTAINER_NAME} from ${IMAGE_NAME}:${IMAGE_TAG} ..."
docker run "${RUN_ARGS[@]}" "${IMAGE_NAME}:${IMAGE_TAG}"

# Follow logs briefly (detached case), then wait for health
if [[ "${DETACH}" = "1" ]]; then
  # quick peek at recent logs
  sleep 2
  docker logs --tail 50 "${CONTAINER_NAME}" || true

  log "Waiting for Matrix Hub to become available on http://127.0.0.1:${APP_HOST_PORT} ..."
  if wait_for_hub "${APP_HOST_PORT}" 60; then
    echo "✔ Matrix Hub is up: http://127.0.0.1:${APP_HOST_PORT}"
    if [[ "${GW_SKIP}" != "1" ]]; then
      echo "✔ MCP‑Gateway is exposed at: http://127.0.0.1:${GW_HOST_PORT}"
    fi
  else
    warn "Matrix Hub did not respond within timeout. Check logs: docker logs -f ${CONTAINER_NAME}"
  fi

  echo ""
  echo "Manage the container:"
  echo "  docker logs -f ${CONTAINER_NAME}"
  echo "  docker stop ${CONTAINER_NAME}"
  echo "  docker rm -f ${CONTAINER_NAME}"
else
  # Foreground mode hands control to Docker (Ctrl+C to stop)
  docker logs -f "${CONTAINER_NAME}"
fi
