#!/usr/bin/env bash
#
# scripts/run_remote_container.sh
# Pulls and runs the remote Docker image (ruslanmv/matrix-hub),
# using --env-file so the app actually sees DATABASE_URL,
# and a named volume at /data so first run is clean, later runs preserve data.
#

set -Eeuo pipefail

# --- Paths ---
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

ENV_FILE_HOST="${PROJECT_ROOT}/.env.gateway.local"   # host-side env file we will pass via --env-file
ENV_EXAMPLE="${PROJECT_ROOT}/.env.gateway.example"

# --- Image & runtime config ---
IMAGE_REPO="${IMAGE_REPO:-ruslanmv/matrix-hub}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
FULL_IMAGE_NAME="${IMAGE_REPO}:${IMAGE_TAG}"

CONTAINER_NAME="${CONTAINER_NAME:-matrix-hub-remote}"
HUB_PORT="${HUB_PORT:-7300}"
GATEWAY_PORT="${GATEWAY_PORT:-4444}"

# Data persistence
DATA_VOLUME="${DATA_VOLUME:-matrixhub-gateway-data}"     # created once, reused later
DATA_DIR_IN_CONTAINER="${DATA_DIR_IN_CONTAINER:-/data}"  # where the DB file will live
DB_FILE_NAME="${DB_FILE_NAME:-mcp.db}"                   # sqlite file name
DB_URL_DEFAULT="sqlite:////${DATA_DIR_IN_CONTAINER}/${DB_FILE_NAME}"

# Optional extra docker args
EXTRA_DOCKER_ARGS=(${EXTRA_DOCKER_ARGS:-})

# --- Pre-flight ---
command -v docker >/dev/null 2>&1 || { echo "❌ Docker not found"; exit 1; }

echo "▶️  Pulling image: ${FULL_IMAGE_NAME}"
docker pull "${FULL_IMAGE_NAME}"

# --- Ensure env file exists and contains a DB URL pointing to /data ---
if [[ ! -f "${ENV_FILE_HOST}" && -f "${ENV_EXAMPLE}" ]]; then
  cp "${ENV_EXAMPLE}" "${ENV_FILE_HOST}"
  echo "ℹ️  Created ${ENV_FILE_HOST} from ${ENV_EXAMPLE}"
fi

touch "${ENV_FILE_HOST}"

# If neither DATABASE_URL nor GATEWAY_DATABASE_URL is present, append a sane default
if ! grep -qE '(^|\s)(DATABASE_URL|GATEWAY_DATABASE_URL)=' "${ENV_FILE_HOST}"; then
  {
    echo "DATABASE_URL=${DB_URL_DEFAULT}"
    # Add aliases just in case the image checks different var names
    echo "GATEWAY_DATABASE_URL=${DB_URL_DEFAULT}"
  } >> "${ENV_FILE_HOST}"
  echo "ℹ️  Added DATABASE_URL and GATEWAY_DATABASE_URL → ${DB_URL_DEFAULT}"
fi

# --- Ensure volume exists (first run it’s new/empty; later runs reused) ---
if docker volume inspect "${DATA_VOLUME}" >/dev/null 2>&1; then
  echo "   - Reusing existing volume '${DATA_VOLUME}' (data preserved)"
else
  echo "   - Creating new volume '${DATA_VOLUME}' (first run: clean data dir)"
  docker volume create "${DATA_VOLUME}" >/dev/null
fi

# --- Stop/remove existing container (volume untouched) ---
if RUNNING_ID="$(docker ps -q -f "name=^${CONTAINER_NAME}$")" && [[ -n "${RUNNING_ID}" ]]; then
  echo "▶️  Stopping existing container ${CONTAINER_NAME} (${RUNNING_ID})…"
  docker stop "${RUNNING_ID}" >/dev/null
fi
if EXISTING_ID="$(docker ps -aq -f "name=^${CONTAINER_NAME}$")" && [[ -n "${EXISTING_ID}" ]]; then
  echo "▶️  Removing existing container ${CONTAINER_NAME} (${EXISTING_ID})…"
  docker rm "${EXISTING_ID}" >/dev/null
fi

# --- Run ---
echo "▶️  Running '${CONTAINER_NAME}' from image '${FULL_IMAGE_NAME}'…"
echo "   - Hub Port:     ${HUB_PORT} -> 7300"
echo "   - Gateway Port: ${GATEWAY_PORT} -> 4444"
echo "   - Env file:     ${ENV_FILE_HOST} (via --env-file)"
echo "   - Volume:       ${DATA_VOLUME} -> ${DATA_DIR_IN_CONTAINER} (DB at ${DB_FILE_NAME})"

docker run -d \
  --name "${CONTAINER_NAME}" \
  -p "${HUB_PORT}:7300" \
  -p "${GATEWAY_PORT}:4444" \
  --env-file "${ENV_FILE_HOST}" \
  -e "DATABASE_URL=${DB_URL_DEFAULT}" \
  -e "GATEWAY_DATABASE_URL=${DB_URL_DEFAULT}" \
  -v "${DATA_VOLUME}:${DATA_DIR_IN_CONTAINER}" \
  --restart unless-stopped \
  "${EXTRA_DOCKER_ARGS[@]}" \
  "${FULL_IMAGE_NAME}"

CID="$(docker ps -q -f "name=^${CONTAINER_NAME}$")"
echo
echo "✅ Started (ID: ${CID:-unknown})."
echo "➡️  Logs:  docker logs -f ${CONTAINER_NAME}"
echo "➡️  Shell: docker exec -it ${CONTAINER_NAME} bash"
echo
echo "Tip: you should now see the startup log say something like:"
echo "     'db_isready - Probing sqlite at ${DATA_DIR_IN_CONTAINER}/${DB_FILE_NAME}'"
