#!/usr/bin/env bash
# scripts/list_tools.sh
# Lists derived `tool` entities from the Matrix Hub DB.

set -euo pipefail

# Optional envs:
#   LIMIT=10           # how many recent tools to show
#   DB_URL=...         # override settings.DATABASE_URL (rarely needed)

if [[ ! -f scripts/list_tools.py ]]; then
  echo "ERROR: scripts/list_tools.py not found. Run from repo root." >&2
  exit 1
fi

export LIMIT="${LIMIT:-10}"
# If you want to override the DB URL for this run:
[[ -n "${DB_URL:-}" ]] && export DATABASE_URL="$DB_URL"

echo "🔎 Listing tool entities (LIMIT=${LIMIT})..."
python3 scripts/list_tools.py
