#!/usr/bin/env bash
#
# scripts/clean_remote_container.sh
# Purge install: stop & remove container, delete data volume, remove image.
#

set -Eeuo pipefail

# --- Defaults (override via env if needed) ---
CONTAINER_NAME="${CONTAINER_NAME:-matrix-hub-remote}"
DATA_VOLUME="${DATA_VOLUME:-matrixhub-gateway-data}"

IMAGE_REPO="${IMAGE_REPO:-ruslanmv/matrix-hub}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

# If true, also remove any other containers created from the same image ID.
FORCE_REMOVE_IMAGE_USERS="${FORCE_REMOVE_IMAGE_USERS:-1}"

echo "🔧 Purging Matrix Hub:"
echo "   - Container : ${CONTAINER_NAME}"
echo "   - Data vol  : ${DATA_VOLUME}"
echo "   - Image     : ${IMAGE_REPO}:${IMAGE_TAG}"
echo

# 1) Stop & remove the container (if present)
RUNNING_ID="$(docker ps -q -f "name=^${CONTAINER_NAME}$")" || true
if [[ -n "${RUNNING_ID}" ]]; then
  echo "▶️  Stopping container '${CONTAINER_NAME}' (${RUNNING_ID})…"
  docker stop "${RUNNING_ID}" >/dev/null
fi

EXISTING_ID="$(docker ps -aq -f "name=^${CONTAINER_NAME}$")" || true
if [[ -n "${EXISTING_ID}" ]]; then
  echo "🗑️  Removing container '${CONTAINER_NAME}' (${EXISTING_ID})…"
  docker rm "${EXISTING_ID}" >/dev/null
else
  echo "ℹ️  No container named '${CONTAINER_NAME}' to remove."
fi

# 2) Remove the data volume (destructive)
if docker volume inspect "${DATA_VOLUME}" >/dev/null 2>&1; then
  echo "🧹 Removing data volume '${DATA_VOLUME}' (destructive)…"
  docker volume rm -f "${DATA_VOLUME}" >/dev/null
else
  echo "ℹ️  Data volume '${DATA_VOLUME}' not found."
fi

# 3) Remove the image (and any containers that still reference it if forced)
IMAGE_ID="$(docker images -q "${IMAGE_REPO}:${IMAGE_TAG}" 2>/dev/null || true)"

if [[ -n "${IMAGE_ID}" ]]; then
  # Optionally remove any other containers created from this image ID
  if [[ "${FORCE_REMOVE_IMAGE_USERS}" == "1" ]]; then
    OTHER_CONTAINERS="$(docker ps -aq --filter "ancestor=${IMAGE_ID}")"
    if [[ -n "${OTHER_CONTAINERS}" ]]; then
      echo "🛑 Found containers using ${IMAGE_REPO}:${IMAGE_TAG} (${IMAGE_ID}). Removing them…"
      # shellcheck disable=SC2086
      docker rm -f ${OTHER_CONTAINERS} >/dev/null || true
    fi
  fi

  # Untag all refs that point to this ID, then remove by ID
  echo "🗑️  Removing image tags pointing to ${IMAGE_ID}…"
  while read -r ref id; do
    [[ "${id}" == "${IMAGE_ID}" ]] && docker rmi "${ref}" >/dev/null || true
  done < <(docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}')

  # Final attempt by ID (handles dangling case)
  docker rmi "${IMAGE_ID}" >/dev/null || true

  # Report status
  if docker images -q "${IMAGE_REPO}:${IMAGE_TAG}" >/dev/null 2>&1 && [[ -n "$(docker images -q "${IMAGE_REPO}:${IMAGE_TAG}")" ]]; then
    echo "⚠️  Image ${IMAGE_REPO}:${IMAGE_TAG} still present (likely re-tagged elsewhere)."
  else
    echo "✅ Image ${IMAGE_REPO}:${IMAGE_TAG} removed."
  fi
else
  echo "ℹ️  Image ${IMAGE_REPO}:${IMAGE_TAG} not found locally."
fi

echo
echo "✅ Purge complete."
echo "Tip: run 'docker system prune -f' to clean dangling layers and networks (optional)."
