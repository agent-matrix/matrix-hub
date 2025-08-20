#!/usr/bin/env bash
#
# scripts/run_container.sh
#
# Run the production image using the working dev-style gateway launcher:
#   scripts/start-mcp-gateway.sh
#
# Env file selection policy:
#   Gateway: use .env.gateway.local, else .env.gateway.example (required)
#   Hub:     use .env,               else .env.example       (required)
#
# Optional: START_DB=1 to launch a Postgres sidecar and create users/DBs.
#

set -Eeuo pipefail

# ---------------------------
# Paths & image names
# ---------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

IMAGE_NAME="${IMAGE_NAME:-matrixhub}"
GIT_SHA="$(git -C "${PROJECT_ROOT}" rev-parse --short HEAD 2>/dev/null || echo local)"
IMAGE_TAG="${IMAGE_TAG:-$(date +%Y%m%d)-${GIT_SHA}}"
FULL_IMAGE_NAME="${IMAGE_NAME}:${IMAGE_TAG}"

CONTAINER_NAME="${CONTAINER_NAME:-matrixhub}"

# ---------------------------
# Ports
# ---------------------------
HUB_PORT="${HUB_PORT:-7300}"
GATEWAY_PORT="${GATEWAY_PORT:-4444}"

# ---------------------------
# Network & Postgres sidecar
# ---------------------------
NETWORK_NAME="${NETWORK_NAME:-matrixhub-net}"
DB_CONTAINER_NAME="${DB_CONTAINER_NAME:-matrixhub-db}"
POSTGRES_VERSION="${POSTGRES_VERSION:-16}"
PG_HOST_PORT="${PG_HOST_PORT:-5432}"

# App DBs & roles
HUB_DB_NAME="${HUB_DB_NAME:-matrixhub}"
HUB_DB_USER="${HUB_DB_USER:-matrix}"
HUB_DB_PASS="${HUB_DB_PASS:-matrix}"

GATEWAY_DB_NAME="${GATEWAY_DB_NAME:-mcpgateway}"
GATEWAY_DB_USER="${GATEWAY_DB_USER:-matrix}"
GATEWAY_DB_PASS="${GATEWAY_DB_PASS:-matrix}"

# Launch Postgres sidecar? (1=yes)
START_DB="${START_DB:-0}"

# ---------------------------
# Env files (HOST) and mount points (CONTAINER)
# ---------------------------
# Hub
HUB_ENV_REAL="${PROJECT_ROOT}/.env"
HUB_ENV_EXAMPLE="${PROJECT_ROOT}/.env.example"
HUB_ENV_IN_CONTAINER="/app/.env"

# Gateway sources live at *project root* (as your start script expects)
GW_ENV_LOCAL_HOST="${PROJECT_ROOT}/.env.gateway.local"
GW_ENV_EXAMPLE_HOST="${PROJECT_ROOT}/.env.gateway.example"
GW_ENV_LOCAL_CONT="/app/.env.gateway.local"
GW_ENV_EXAMPLE_CONT="/app/.env.gateway.example"

# Start script
HOST_START_SCRIPT="${PROJECT_ROOT}/scripts/start-mcp-gateway.sh"
CONT_START_SCRIPT="/app/scripts/start-mcp-gateway.sh"

# ---------------------------
# Helpers
# ---------------------------
step() { printf "▶ %s\n" "$*"; }
info() { printf "ℹ %s\n" "$*"; }
warn() { printf "⚠ %s\n" "$*\n" >&2; }
die()  { printf "✖ %s\n" "$*\n" >&2; exit 1; }

ensure_network() {
  if ! docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
    step "Creating network ${NETWORK_NAME}"
    docker network create "${NETWORK_NAME}" >/dev/null
  fi
}

detect_db_super_creds() {
  DB_SUPER_USER="postgres"; DB_SUPER_PASS="postgres"
  if docker ps -a --format '{{.Names}}' | grep -qx "${DB_CONTAINER_NAME}"; then
    local envdump
    envdump="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${DB_CONTAINER_NAME}" 2>/dev/null || true)"
    while IFS= read -r line; do
      case "$line" in
        POSTGRES_USER=*)     DB_SUPER_USER="${line#*=}";;
        POSTGRES_PASSWORD=*) DB_SUPER_PASS="${line#*=}";;
      esac
    done <<< "${envdump}"
  fi
  export DB_SUPER_USER DB_SUPER_PASS
}

start_db_if_requested() {
  [[ "${START_DB}" != "1" ]] && return 0
  ensure_network

  if ! docker ps -a --format '{{.Names}}' | grep -qx "${DB_CONTAINER_NAME}"; then
    step "Launching Postgres '${DB_CONTAINER_NAME}' (v${POSTGRES_VERSION})"
    docker run -d \
      --name "${DB_CONTAINER_NAME}" \
      --network "${NETWORK_NAME}" \
      -e POSTGRES_USER=postgres \
      -e POSTGRES_PASSWORD=postgres \
      -e POSTGRES_DB=postgres \
      -p "${PG_HOST_PORT}:5432" \
      --health-cmd="pg_isready -q -h 127.0.0.1 -p 5432 -d postgres" \
      --health-interval=10s --health-timeout=5s --health-retries=5 \
      --restart unless-stopped \
      postgres:${POSTGRES_VERSION} >/dev/null
  else
    if ! docker ps --format '{{.Names}}' | grep -qx "${DB_CONTAINER_NAME}"; then
      step "Starting existing Postgres '${DB_CONTAINER_NAME}'"
      docker start "${DB_CONTAINER_NAME}" >/dev/null
    else
      info "Postgres '${DB_CONTAINER_NAME}' already running"
    fi
  fi

  step "Waiting for Postgres to be healthy..."
  until [[ "$(docker inspect -f '{{.State.Health.Status}}' "${DB_CONTAINER_NAME}")" == "healthy" ]]; do
    sleep 1
  done

  detect_db_super_creds

  step "Ensuring roles & databases exist (idempotent)"
  # roles
  if ! docker exec -e PGPASSWORD="${DB_SUPER_PASS}" "${DB_CONTAINER_NAME}" \
       psql -U "${DB_SUPER_USER}" -h 127.0.0.1 -tAc "SELECT 1 FROM pg_roles WHERE rolname='${HUB_DB_USER}'" | grep -q 1; then
    docker exec -e PGPASSWORD="${DB_SUPER_PASS}" -i "${DB_CONTAINER_NAME}" \
      psql -U "${DB_SUPER_USER}" -h 127.0.0.1 -v ON_ERROR_STOP=1 \
      -c "CREATE ROLE ${HUB_DB_USER} LOGIN PASSWORD '${HUB_DB_PASS}';"
  fi
  if ! docker exec -e PGPASSWORD="${DB_SUPER_PASS}" "${DB_CONTAINER_NAME}" \
       psql -U "${DB_SUPER_USER}" -h 127.0.0.1 -tAc "SELECT 1 FROM pg_roles WHERE rolname='${GATEWAY_DB_USER}'" | grep -q 1; then
    docker exec -e PGPASSWORD="${DB_SUPER_PASS}" -i "${DB_CONTAINER_NAME}" \
      psql -U "${DB_SUPER_USER}" -h 127.0.0.1 -v ON_ERROR_STOP=1 \
      -c "CREATE ROLE ${GATEWAY_DB_USER} LOGIN PASSWORD '${GATEWAY_DB_PASS}';"
  fi
  # dbs
  if ! docker exec -e PGPASSWORD="${DB_SUPER_PASS}" "${DB_CONTAINER_NAME}" \
       psql -U "${DB_SUPER_USER}" -h 127.0.0.1 -tAc "SELECT 1 FROM pg_database WHERE datname='${HUB_DB_NAME}'" | grep -q 1; then
    docker exec -e PGPASSWORD="${DB_SUPER_PASS}" -i "${DB_CONTAINER_NAME}" \
      psql -U "${DB_SUPER_USER}" -h 127.0.0.1 -v ON_ERROR_STOP=1 \
      -c "CREATE DATABASE ${HUB_DB_NAME} OWNER ${HUB_DB_USER};"
  fi
  if ! docker exec -e PGPASSWORD="${DB_SUPER_PASS}" "${DB_CONTAINER_NAME}" \
       psql -U "${DB_SUPER_USER}" -h 127.0.0.1 -tAc "SELECT 1 FROM pg_database WHERE datname='${GATEWAY_DB_NAME}'" | grep -q 1; then
    docker exec -e PGPASSWORD="${DB_SUPER_PASS}" -i "${DB_CONTAINER_NAME}" \
      psql -U "${DB_SUPER_USER}" -h 127.0.0.1 -v ON_ERROR_STOP=1 \
      -c "CREATE DATABASE ${GATEWAY_DB_NAME} OWNER ${GATEWAY_DB_USER};"
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
  GW_MOUNT_OPTS=()  # will hold one -v mapping to either local or example
  if [[ -f "${GW_ENV_LOCAL_HOST}" ]]; then
    GW_MOUNT_OPTS=( -v "${GW_ENV_LOCAL_HOST}:${GW_ENV_LOCAL_CONT}:ro" )
    info "Using Gateway env: ${GW_ENV_LOCAL_HOST} → ${GW_ENV_LOCAL_CONT}"
  elif [[ -f "${GW_ENV_EXAMPLE_HOST}" ]]; then
    GW_MOUNT_OPTS=( -v "${GW_ENV_EXAMPLE_HOST}:${GW_ENV_EXAMPLE_CONT}:ro" )
    info "Using Gateway env example: ${GW_ENV_EXAMPLE_HOST} → ${GW_ENV_EXAMPLE_CONT}"
  else
    die "Neither ${GW_ENV_LOCAL_HOST} nor ${GW_ENV_EXAMPLE_HOST} found."
  fi
}

stop_rm_if_exists() {
  local name="$1"
  # FIX: Check for command output, not just exit code.
  # This checks if the container is currently running.
  if [ -n "$(docker ps -q -f name="^${name}$")" ]; then
    step "Stopping ${name}"
    docker stop "${name}" >/dev/null
  fi
  # FIX: Check for command output, not just exit code.
  # This checks if the container exists at all (running or stopped).
  if [ -n "$(docker ps -aq -f name="^${name}$")" ]; then
    step "Removing ${name}"
    docker rm "${name}" >/dev/null
  fi
}

# ---------------------------
# Main
# ---------------------------
step "Starting ${CONTAINER_NAME} from ${FULL_IMAGE_NAME}"

[[ -f "${HOST_START_SCRIPT}" ]] || die "Missing ${HOST_START_SCRIPT}."

ensure_network
start_db_if_requested
pick_hub_env
pick_gateway_env_sources
stop_rm_if_exists "${CONTAINER_NAME}"

# Fallback to :latest if the exact tag isn't local
if ! docker image inspect "${FULL_IMAGE_NAME}" >/dev/null 2>&1; then
  warn "${FULL_IMAGE_NAME} not found locally; using ${IMAGE_NAME}:latest"
  FULL_IMAGE_NAME="${IMAGE_NAME}:latest"
fi

# Run container:
# - Mount Hub env to /app/.env (read-only)
# - Mount Gateway env source to /app/.env.gateway.local OR /app/.env.gateway.example
# - Mount the working start script
# - Start gateway via script (it copies env into /app/mcpgateway/.env and handles Alembic logic)
# - Start Hub via gunicorn in the foreground (keeps container alive)
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
step "Container is up."
info "Logs:    docker logs -f ${CONTAINER_NAME}"
info "Hub:     http://localhost:${HUB_PORT}/"
info "Gateway: http://localhost:${GATEWAY_PORT}/"
