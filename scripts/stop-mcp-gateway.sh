#!/usr/bin/env bash
# Stop-MCP-Gateway.sh
set -euo pipefail

# Try to find and kill any running mcpgateway processes
if pgrep -f 'mcpgateway --host' >/dev/null; then
  echo "Stopping MCP Gateway…"
  pkill -f 'mcpgateway --host'
  echo "✅ MCP Gateway stopped."
else
  echo "ℹ️  No MCP Gateway process found."
fi

