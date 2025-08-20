#!/usr/bin/env bash
set -euo pipefail

# Normalize CRLF in env files (safe no-op on LF)
[ -f /app/.env ] && sed -i 's/\r$//' /app/.env || true
[ -f /app/mcpgateway/.env ] && sed -i 's/\r$//' /app/mcpgateway/.env || true

# 🔒 Ensure Gateway cannot fall back to SQLite:
# remove any local DB that might exist from bind-mounts or previous runs
if [ -f /app/mcpgateway/mcp.db ]; then
  echo "💡 Removing stale /app/mcpgateway/mcp.db to prevent SQLite fallback"
  rm -f /app/mcpgateway/mcp.db || true
fi

# Optional: show effective DB URL (helps confirm Postgres is wired)
if [ -f /app/mcpgateway/.env ]; then
  set +u
  # shellcheck disable=SC1091
  . /app/mcpgateway/.env
  set -u
  echo "ℹ️ Gateway DATABASE_URL=${DATABASE_URL:-<unset>}"
fi

exec "$@"
