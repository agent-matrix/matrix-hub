#!/usr/bin/env bash
set -Eeuo pipefail

# Load .env if present
if [ -f ".env" ]; then
  # shellcheck disable=SC2046
  export $(grep -v '^\s*#' .env | xargs -0 -I {} bash -c 'echo {}' 2>/dev/null | tr -d '\r' || true)
fi

APP_MODULE=${APP_MODULE:-"src.app:app"}
HOST=${HOST:-"0.0.0.0"}
PORT=${PORT:-"7300"}

echo "▶ Starting Matrix Hub (dev) on http://${HOST}:${PORT}"
echo "  APP_MODULE=${APP_MODULE}"
echo "  LOG_LEVEL=${LOG_LEVEL:-INFO}"

exec uvicorn "${APP_MODULE}" --reload --host "${HOST}" --port "${PORT}" --proxy-headers
