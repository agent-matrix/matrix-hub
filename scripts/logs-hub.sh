#!/usr/bin/env bash
set -euo pipefail

# Tail Matrix Hub logs.
# Modes:
#   1) File mode (default): tail ./logs/matrixhub.log or best-match in ./logs/*.log
#   2) Docker mode:         use 'docker logs' for the running container
#
# ENV:
#   LOG_FILE, LINES (default 200), FOLLOW (default follow),
#   DOCKER (0/1), CONTAINER_NAME (default "matrix-hub")
#
# Flags:
#   --file PATH
#   --lines N
#   --no-follow
#   --docker                (force docker mode)
#   --container-name NAME
#   -h|--help

LOG_FILE="${LOG_FILE:-./logs/matrixhub.log}"
LINES="${LINES:-200}"
FOLLOW=1
DOCKER="${DOCKER:-0}"
CONTAINER_NAME="${CONTAINER_NAME:-matrix-hub}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file) LOG_FILE="$2"; shift 2 ;;
    --lines) LINES="$2"; shift 2 ;;
    --no-follow) FOLLOW=0; shift ;;
    --docker) DOCKER=1; shift ;;
    --container-name) CONTAINER_NAME="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF
Usage: $0 [--file PATH] [--lines N] [--no-follow] [--docker] [--container-name NAME]
ENV: LOG_FILE, LINES, DOCKER, CONTAINER_NAME
EOF
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ "$DOCKER" -eq 1 ]]; then
  command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not found." >&2; exit 2; }
  echo "▶ Streaming Docker logs for container '${CONTAINER_NAME}' (last ${LINES} lines)"
  if [[ "$FOLLOW" -eq 1 ]]; then
    docker logs --tail "${LINES}" -f "${CONTAINER_NAME}"
  else
    docker logs --tail "${LINES}" "${CONTAINER_NAME}"
  fi
  exit 0
fi

# File mode
if [[ ! -f "$LOG_FILE" ]]; then
  # Try to pick a reasonable default from ./logs
  CANDIDATE="$(ls -1t ./logs/*hub*.log ./logs/uvicorn*.log 2>/dev/null | head -n1 || true)"
  if [[ -n "${CANDIDATE}" ]]; then
    echo "⚠️  Log file not found at '$LOG_FILE'; using newest: ${CANDIDATE}"
    LOG_FILE="${CANDIDATE}"
  else
    echo "❌ No Matrix Hub log file found. Expected '$LOG_FILE' or something like ./logs/uvicorn*.log"
    echo "   If you're in dev mode (e.g., 'make dev' or 'make dev-sh'), logs are printed to the same terminal."
    echo "   For file-based logs, run production mode and redirect/tee app output to ./logs/matrixhub.log."
    exit 1
  fi
fi

echo "▶ Tailing Matrix Hub log: ${LOG_FILE} (last ${LINES} lines)"
if [[ "$FOLLOW" -eq 1 ]]; then
  tail -n "${LINES}" -f "${LOG_FILE}"
else
  tail -n "${LINES}" "${LOG_FILE}"
fi
