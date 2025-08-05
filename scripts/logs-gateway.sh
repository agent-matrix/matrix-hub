#!/usr/bin/env bash
set -euo pipefail

# Tail MCP Gateway logs.
# Defaults:
#   PROJECT_DIR=mcpgateway
#   LOG_FILE=\$PROJECT_DIR/logs/mcpgateway.log
# ENV:
#   PROJECT_DIR, LOG_FILE, LINES, FOLLOW
# Flags:
#   --file PATH      (override log file)
#   --lines N        (default 200)
#   --no-follow      (do not -f)
#   -h|--help

PROJECT_DIR="${PROJECT_DIR:-mcpgateway}"
DEFAULT_FILE="${PROJECT_DIR}/logs/mcpgateway.log"
LOG_FILE="${LOG_FILE:-$DEFAULT_FILE}"
LINES="${LINES:-200}"
FOLLOW=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file) LOG_FILE="$2"; shift 2 ;;
    --lines) LINES="$2"; shift 2 ;;
    --no-follow) FOLLOW=0; shift ;;
    -h|--help)
      cat <<EOF
Usage: $0 [--file PATH] [--lines N] [--no-follow]
ENV: PROJECT_DIR, LOG_FILE, LINES
Default file: ${DEFAULT_FILE}
EOF
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ ! -f "$LOG_FILE" ]]; then
  # Try to find newest .log under PROJECT_DIR/logs
  CANDIDATE="$(ls -1t "${PROJECT_DIR}/logs/"*.log 2>/dev/null | head -n1 || true)"
  if [[ -n "${CANDIDATE}" ]]; then
    echo "⚠️  Log file not found at '$LOG_FILE'; using newest: ${CANDIDATE}"
    LOG_FILE="${CANDIDATE}"
  else
    echo "❌ No log file found. Expected at '$LOG_FILE' or in '${PROJECT_DIR}/logs/'."
    echo "   Make sure you started the gateway (e.g., 'make gateway-start')."
    exit 1
  fi
fi

echo "▶ Tailing MCP Gateway log: ${LOG_FILE} (last ${LINES} lines)"
if [[ "$FOLLOW" -eq 1 ]]; then
  tail -n "${LINES}" -f "${LOG_FILE}"
else
  tail -n "${LINES}" "${LOG_FILE}"
fi
