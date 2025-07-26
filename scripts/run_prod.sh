#!/usr/bin/env bash
set -Eeuo pipefail

APP_MODULE=${APP_MODULE:-"src.app:app"}
HOST=${HOST:-"0.0.0.0"}
PORT=${PORT:-"7300"}
GUNICORN_WORKERS=${GUNICORN_WORKERS:-"2"}
GUNICORN_TIMEOUT=${GUNICORN_TIMEOUT:-"120"}

echo "▶ Starting Matrix Hub (prod) with gunicorn"
echo "  APP_MODULE=${APP_MODULE}"
echo "  BIND=${HOST}:${PORT}"
echo "  WORKERS=${GUNICORN_WORKERS}  TIMEOUT=${GUNICORN_TIMEOUT}s"

exec gunicorn \
  "${APP_MODULE}" \
  -k uvicorn.workers.UvicornWorker \
  -w "${GUNICORN_WORKERS}" \
  -b "${HOST}:${PORT}" \
  --timeout "${GUNICORN_TIMEOUT}" \
  --access-logfile - \
  --error-logfile - \
  --log-level info
