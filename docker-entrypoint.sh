#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# matrix-hub container entrypoint
#
# Responsibilities (in order):
#   1. Normalise CRLF in mounted env files.
#   2. Source /app/.env so DATABASE_URL_PRIMARY / DATABASE_URL_FALLBACK
#      reach this shell (without leaking other vars into the global env).
#   3. Resolve DATABASE_URL via scripts/select_database_url.sh — picks the
#      working DB at boot (Aiven primary, OL9 fallback) and exports a
#      single DATABASE_URL for everything downstream.
#   4. Persist the resolved DATABASE_URL into both /app/.env and
#      /app/mcpgateway/.env so supervisord-spawned processes inherit it.
#   5. Strip any leftover SQLite to prevent silent fallback.
#   6. exec the supervisord command passed in CMD.
#
# Backwards-compatible: if DATABASE_URL is already set explicitly in the
# env file, the selector is a no-op.
# ---------------------------------------------------------------------------

# 1. Normalise CRLF (safe no-op on LF)
[ -f /app/.env ]            && sed -i 's/\r$//' /app/.env            || true
[ -f /app/mcpgateway/.env ] && sed -i 's/\r$//' /app/mcpgateway/.env || true

# 2. Pull only the DB-related vars out of /app/.env into this shell.
#    We deliberately don't `. /app/.env` wholesale because that would
#    spam every var into the environment seen by `set -u`.
read_env_var() {
  local name="$1" file="$2"
  [ -f "$file" ] || return 0
  local v
  v="$(grep -E "^${name}=" "$file" | head -n1 | cut -d= -f2- | tr -d '\r' | sed -E 's/^"(.*)"$/\1/; s#^'"'"'(.*)'"'"'$#\1#')"
  [ -n "$v" ] && export "$name=$v" || true
}
read_env_var DATABASE_URL          /app/.env
read_env_var DATABASE_URL_PRIMARY  /app/.env
read_env_var DATABASE_URL_FALLBACK /app/.env
read_env_var PROBE_TIMEOUT         /app/.env
read_env_var PROBE_RETRIES         /app/.env
read_env_var ON_FALLBACK           /app/.env

# 3. Resolve DATABASE_URL.
if [ -f /app/scripts/select_database_url.sh ]; then
  # The selector exits 0 on success and exports DATABASE_URL.
  # If both primary and fallback are unreachable it exits non-zero, which
  # means the container fails fast instead of running on a broken DB.
  set +u
  # shellcheck disable=SC1091
  . /app/scripts/select_database_url.sh
  set -u
else
  echo "ℹ️ /app/scripts/select_database_url.sh not present — skipping primary/fallback selection"
fi

# 4. Propagate the resolved DATABASE_URL into the env files so any process
#    started by supervisord (including the MCP gateway) picks it up.
upsert_env_var() {
  local name="$1" value="$2" file="$3"
  [ -f "$file" ] || return 0
  if grep -qE "^${name}=" "$file"; then
    # Replace the line. Use # as the sed delimiter so / in URLs is fine.
    sed -i "s#^${name}=.*#${name}=${value//#/\\#}#" "$file"
  else
    printf '\n%s=%s\n' "$name" "$value" >> "$file"
  fi
}
if [ -n "${DATABASE_URL:-}" ]; then
  upsert_env_var DATABASE_URL "$DATABASE_URL" /app/.env
  upsert_env_var DATABASE_URL "$DATABASE_URL" /app/mcpgateway/.env
  # Surface the fact that we're on the fallback so /health can flag it.
  if [ "${MATRIXHUB_DB_USED:-}" = "fallback" ]; then
    upsert_env_var MATRIXHUB_DB_USED "fallback" /app/.env
    echo "::warning::matrix-hub started on FALLBACK database. Restore primary ASAP."
  fi
fi

# 5. Belt-and-suspenders: prevent silent SQLite fallback in the gateway.
if [ -f /app/mcpgateway/mcp.db ]; then
  echo "💡 Removing stale /app/mcpgateway/mcp.db to prevent SQLite fallback"
  rm -f /app/mcpgateway/mcp.db || true
fi

# Optional: show effective DB URL (with password masked) so logs confirm
# Postgres is wired without leaking credentials.
masked() { echo "$1" | sed -E 's#(://[^:]+:)[^@]+(@)#\1***\2#'; }
if [ -n "${DATABASE_URL:-}" ]; then
  echo "ℹ️ Hub     DATABASE_URL=$(masked "$DATABASE_URL")"
fi
if [ -f /app/mcpgateway/.env ]; then
  GW_URL="$(grep -E '^DATABASE_URL=' /app/mcpgateway/.env | head -n1 | cut -d= -f2- | tr -d '\r')"
  [ -n "$GW_URL" ] && echo "ℹ️ Gateway DATABASE_URL=$(masked "$GW_URL")"
fi

# 6. Hand off to supervisord (or whatever was passed in CMD).
exec "$@"
