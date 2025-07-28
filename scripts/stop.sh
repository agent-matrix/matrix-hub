#!/usr/bin/env bash
# scripts/stop.sh

set -euo pipefail

# Load .env if present
[ -f .env ] && export $(grep -v '^\s*#' .env | xargs)

PORT=${PORT:-7300}

echo "▶ Stopping any process listening on port ${PORT}…"
# On macOS/Linux: find PID(s) listening on TCP port and kill them
if command -v lsof >/dev/null 2>&1; then
  PIDS=$(lsof -ti tcp:${PORT} || true)
elif command -v fuser >/dev/null 2>&1; then
  PIDS=$(fuser ${PORT}/tcp 2>/dev/null || true)
else
  echo "⚠️  Neither lsof nor fuser found; please kill the server manually."
  exit 1
fi

if [ -z "$PIDS" ]; then
  echo "✔ No process found on port ${PORT}."
else
  echo "Killing PID(s): $PIDS"
  kill $PIDS
  echo "✔ Stopped."
fi
