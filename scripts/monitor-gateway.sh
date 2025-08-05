#!/usr/bin/env bash
set -euo pipefail

# Simple health monitor for the MCP Gateway.
# ENV (or flags):
#   HOST=0.0.0.0 PORT=4444 INTERVAL=5
# Flags:
#   --host H --port P --interval S --once
#
# Exit codes:
#   0 = (loop) ran; last check healthy OR (once) healthy
#   1 = unhealthy / unreachable encountered
#   2 = misconfigured (missing curl / bad args)

HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-4444}"
INTERVAL="${INTERVAL:-5}"
RUN_ONCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --once) RUN_ONCE=1; shift ;;
    -h|--help)
      cat <<EOF
Usage: $0 [--host H] [--port P] [--interval S] [--once]
ENV: HOST, PORT, INTERVAL
EOF
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

command -v curl >/dev/null 2>&1 || { echo "ERROR: 'curl' is required." >&2; exit 2; }

BASE_URL="http://${HOST}:${PORT}"
HEALTH="${BASE_URL}/health"
METRICS="${BASE_URL}/metrics"

timestamp() { date "+%Y-%m-%d %H:%M:%S"; }

check_once() {
  local ts
  ts="$(timestamp)"
  if curl -fsS --max-time 3 "${HEALTH}" >/dev/null 2>&1; then
    echo "[$ts] ✅ Gateway healthy: ${HEALTH}"
    if curl -fsS --max-time 2 "${METRICS}" >/dev/null 2>&1; then
      echo "[$ts] ℹ️  Metrics available at ${METRICS}"
    fi
    return 0
  else
    echo "[$ts] ❌ Gateway UNHEALTHY/UNREACHABLE: ${HEALTH}"
    return 1
  fi
}

if [[ "$RUN_ONCE" -eq 1 ]]; then
  check_once || exit 1
  exit 0
fi

echo "▶ Monitoring MCP Gateway at ${BASE_URL} every ${INTERVAL}s (Ctrl+C to stop)"
RC=0
while true; do
  if ! check_once; then RC=1; fi
  sleep "${INTERVAL}"
done

exit "${RC}"
