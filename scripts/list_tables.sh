#!/usr/bin/env bash
# scripts/list_tables.sh
# Prints all tables in the Matrix Hub DB (with columns & row counts)
# by running scripts/list_tables.py

set -euo pipefail

if [[ ! -f scripts/list_tables.py ]]; then
  echo "ERROR: scripts/list_tables.py not found. Run from repo root." >&2
  exit 1
fi

echo "🔎 Listing tables (and row counts) in Matrix Hub database..."
python3 scripts/list_tables.py
