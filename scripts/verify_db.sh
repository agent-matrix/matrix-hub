#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# Load .env if present
if [ -f ".env" ]; then
  set -a; . ".env"; set +a
fi

DB_URL="${DATABASE_URL:-sqlite+pysqlite:///./data/catalog.sqlite}"
echo "👉 Using DATABASE_URL=${DB_URL}"

hr() { printf '\n%s\n' "----------------------------------------"; }

if [[ "${DB_URL}" =~ ^sqlite\+pysqlite:/// ]]; then
  DB_PATH="${DB_URL#sqlite+pysqlite:///}"
  case "${DB_PATH}" in
    /*) SQLITE_FILE="${DB_PATH}" ;;
    *)  SQLITE_FILE="${ROOT_DIR}/${DB_PATH}" ;;
  esac

  echo "🗄 SQLite file: ${SQLITE_FILE}"
  mkdir -p "$(dirname "${SQLITE_FILE}")"

  if [ ! -f "${SQLITE_FILE}" ]; then
    echo "⚠ DB file does not exist yet. Start the app once (make dev) or run migrations (make upgrade) to create it."
    exit 1
  fi

  if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "✖ sqlite3 CLI not found. Install it (apt-get install sqlite3 / brew install sqlite)."
    exit 2
  fi

  hr
  echo "📋 Tables present:"
  # List tables
  sqlite3 "${SQLITE_FILE}" <<'SQL'
.headers on
.mode column
SELECT name AS table_name
FROM sqlite_master
WHERE type='table'
ORDER BY name;
SQL

  hr
  echo "📊 Row counts (for known tables):"
  # Known/expected application tables — adjust if your schema differs
  KNOWN_TABLES=(entities tools servers resources prompts)

  # Pretty header
  printf "%-16s %10s\n" "tbl" "rows"
  printf "%-16s %10s\n" "----------------" "----------"

  for t in "${KNOWN_TABLES[@]}"; do
    # Check table exists
    if sqlite3 "${SQLITE_FILE}" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='${t}';" | grep -q 1; then
      # Safe: run a simple count
      cnt="$(sqlite3 "${SQLITE_FILE}" "SELECT COUNT(*) FROM ${t};" || echo 0)"
      printf "%-16s %10s\n" "${t}" "${cnt}"
    else
      printf "%-16s %10s\n" "${t}" "0 (missing)"
    fi
  done

  hr
  echo "🧭 Sample entities (latest 10):"
  if sqlite3 "${SQLITE_FILE}" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='entities';" | grep -q 1; then
    sqlite3 "${SQLITE_FILE}" <<'SQL'
.headers on
.mode column
SELECT uid, type, name, version, created_at
FROM entities
ORDER BY created_at DESC
LIMIT 10;
SQL
  else
    echo "Table 'entities' not found."
  fi

elif [[ "${DB_URL}" =~ ^postgres ]]; then
  echo "🗄 Postgres connection string detected."
  if ! command -v psql >/dev/null 2>&1; then
    echo "✖ psql CLI not found. Install it and re-run."
    exit 2
  fi

  export DATABASE_URL="${DB_URL}"

  hr
  echo "📋 Tables and row counts:"
  psql "${DB_URL}" -v ON_ERROR_STOP=1 <<'SQL'
\pset format aligned
\pset border 1
\dt

-- Adjust to your schema: use 'tbl' alias, avoid the reserved word 'table'
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name='entities') THEN
    RAISE NOTICE 'entities | %', (SELECT COUNT(*) FROM entities);
  ELSE
    RAISE NOTICE 'entities | missing';
  END IF;

  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name='tools') THEN
    RAISE NOTICE 'tools    | %', (SELECT COUNT(*) FROM tools);
  ELSE
    RAISE NOTICE 'tools    | missing';
  END IF;

  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name='servers') THEN
    RAISE NOTICE 'servers  | %', (SELECT COUNT(*) FROM servers);
  ELSE
    RAISE NOTICE 'servers  | missing';
  END IF;

  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name='resources') THEN
    RAISE NOTICE 'resources| %', (SELECT COUNT(*) FROM resources);
  ELSE
    RAISE NOTICE 'resources| missing';
  END IF;

  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name='prompts') THEN
    RAISE NOTICE 'prompts  | %', (SELECT COUNT(*) FROM prompts);
  ELSE
    RAISE NOTICE 'prompts  | missing';
  END IF;
END $$;

\echo
\echo '🧭 Sample entities (latest 10):'
SELECT uid, type, name, version, created_at
FROM entities
ORDER BY created_at DESC
LIMIT 10;
SQL

else
  echo "✖ Unsupported DATABASE_URL scheme. Expected sqlite+pysqlite:// or postgres://"
  exit 3
fi
