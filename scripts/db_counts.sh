#!/usr/bin/env bash
# Count key tables in a MatrixHub database to verify ingestion.
# Supports both PostgreSQL and SQLite by detecting the scheme in DATABASE_URL.
#
# Usage:
#   Simply run the script. It will read the DATABASE_URL from your .env file.

set -Eeuo pipefail

# Load .env if present
if [[ -f .env ]]; then
  echo "▶ Loading environment from .env"
  set -a; 
  # shellcheck disable=SC1091
  source .env; 
  set +a
fi

# Ensure DATABASE_URL is set
: "${DATABASE_URL:?Set DATABASE_URL in your .env file}"


# --- Detect database type and execute the appropriate commands ---

if [[ "$DATABASE_URL" == postgresql* ]]; then
  ##
  ## PostgreSQL Logic
  ##
  echo "✅ Detected PostgreSQL database."

  # Convert the Python connection string to a psql-compatible one
  db_conn="${DATABASE_URL/postgresql+psycopg/postgresql}"

  psql "$db_conn" -v ON_ERROR_STOP=1 -P pager=off <<'SQL'
\pset format aligned
\pset linestyle unicode
\pset border 2

-- Who/where
SELECT current_database() AS db, current_user AS usr, inet_server_addr() AS server_ip, now() AT TIME ZONE 'UTC' AS utc_now;

-- Totals
SELECT COUNT(*) AS remotes FROM public.remote;
SELECT COUNT(*) AS entities FROM public.entity;
SELECT COUNT(*) AS embedding_chunks FROM public.embedding_chunk;

-- By type
SELECT type, COUNT(*) AS n
FROM public.entity
GROUP BY type
ORDER BY n DESC;

-- Pending/failed gateway status for servers
SELECT
  COUNT(*) FILTER (WHERE type='mcp_server' AND gateway_registered_at IS NULL) AS pending_gateways,
  COUNT(*) FILTER (WHERE gateway_error IS NOT NULL)                           AS with_gateway_error
FROM public.entity;

-- Optional: sample a few recent entities
SELECT uid, type, name, version, gateway_registered_at, left(source_url, 120) AS source_url
FROM public.entity
ORDER BY created_at DESC NULLS LAST
LIMIT 10;
SQL

elif [[ "$DATABASE_URL" == sqlite* ]]; then
  ##
  ## SQLite Logic
  ##
  echo "✅ Detected SQLite database."
  
  # Extract the file path from the connection string
  db_path="$(echo "$DATABASE_URL" | sed 's|.*:///||')"
  
  if [[ ! -f "$db_path" ]]; then
    echo "❌ Error: SQLite database file not found at: $db_path"
    exit 1
  fi

  sqlite3 "$db_path" <<'SQL'
.headers on
.mode column

-- Database file
SELECT file AS db_path, datetime('now') as utc_now FROM pragma_database_list;

-- Totals
SELECT COUNT(*) AS remotes FROM remote;
SELECT COUNT(*) AS entities FROM entity;
SELECT COUNT(*) AS embedding_chunks FROM embedding_chunk;

-- By type
SELECT type, COUNT(*) AS n
FROM entity
GROUP BY type
ORDER BY n DESC;

-- Pending/failed gateway status for servers (using compatible syntax)
SELECT
  SUM(CASE WHEN type='mcp_server' AND gateway_registered_at IS NULL THEN 1 ELSE 0 END) AS pending_gateways,
  SUM(CASE WHEN gateway_error IS NOT NULL THEN 1 ELSE 0 END)                           AS with_gateway_error
FROM entity;

-- Optional: sample a few recent entities
SELECT uid, type, name, version, gateway_registered_at, substr(source_url, 1, 120) AS source_url
FROM entity
ORDER BY created_at DESC
LIMIT 10;
SQL

else
  echo "❌ Error: Unsupported database type in DATABASE_URL."
  echo "   Expected a string starting with 'postgresql' or 'sqlite'."
  exit 1
fi