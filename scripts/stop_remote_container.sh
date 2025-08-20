#!/usr/bin/env bash
#
# scripts/stop_remote_container.sh
# Gracefully stop the running Matrix Hub container (non-destructive).
#

set -Eeuo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-matrix-hub-remote}"

# Is it running?
RUNNING_ID="$(docker ps -q -f "name=^${CONTAINER_NAME}$")"

if [[ -n "${RUNNING_ID}" ]]; then
  echo "▶️  Stopping container '${CONTAINER_NAME}' (${RUNNING_ID})…"
  docker stop "${RUNNING_ID}"
  echo "✅ Stopped."
else
  # Maybe it exists but is already stopped?
  EXISTING_ID="$(docker ps -aq -f "name=^${CONTAINER_NAME}$")"
  if [[ -n "${EXISTING_ID}" ]]; then
    echo "ℹ️  Container '${CONTAINER_NAME}' is not running (ID: ${EXISTING_ID}). Nothing to do."
  else
    echo "ℹ️  No container named '${CONTAINER_NAME}' found."
  fi
fi
