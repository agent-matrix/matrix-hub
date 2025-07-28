#!/usr/bin/env bash
# force-mcp-stop.sh: checks for any process listening on port 4444 (0.0.0.0:4444) and kills it if found

PORT=4444

# Find the PID(s) of processes listening on TCP port 4444
# Using lsof for simplicity; falls back to ss if lsof is not available
if command -v lsof &> /dev/null; then
  PIDS=$(lsof -ti TCP:${PORT})
else
  PIDS=$(ss -tulpn "sport = :${PORT}" 2>/dev/null | awk '/LISTEN/ {print $6}' | cut -d"," -f2 | cut -d"=" -f2)
fi

if [ -z "${PIDS}" ]; then
  echo "No process found listening on port ${PORT}."
  exit 0
fi

# Kill each process found
for PID in ${PIDS}; do
  if kill -0 ${PID} &> /dev/null; then
    echo "Killing process ${PID} on port ${PORT}..."
    kill -9 ${PID} && echo "Process ${PID} terminated." || echo "Failed to kill process ${PID}."
  else
    echo "Process ${PID} not running. Skipping."
  fi
done
