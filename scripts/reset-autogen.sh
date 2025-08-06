#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# reset-autogen.sh
#
# PRO USE: Run this ONCE to bootstrap your DB schema from models via Alembic.
# Deletes DB and migration history, autogenerates a new migration, applies it.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DB_FILE="$PROJECT_ROOT/data/catalog.sqlite"
VERSIONS_DIR="$PROJECT_ROOT/alembic/versions"
ALEMBIC_INI="$PROJECT_ROOT/alembic.ini"

echo
echo "🚨 DANGER: This will DELETE your DB and all existing Alembic migrations!"
echo "   DB:        $DB_FILE"
echo "   Migrations: $VERSIONS_DIR"
echo
read -rp "Type 'RESET' to proceed: " CONFIRM
echo
if [[ "$CONFIRM" != "RESET" ]]; then
  echo "❌ Aborted. No changes made."
  exit 1
fi

cd "$PROJECT_ROOT"

# 1) Remove the database file
if [[ -f "$DB_FILE" ]]; then
  echo "🗑️  Deleting database: $DB_FILE"
  rm -f "$DB_FILE"
else
  echo "⚪ No existing database to delete."
fi

# 2) Remove migration files
if [[ -d "$VERSIONS_DIR" ]]; then
  echo "🗑️  Deleting all migration files in: $VERSIONS_DIR"
  rm -rf "$VERSIONS_DIR"/*
else
  echo "⚪ Migrations directory did not exist; creating..."
  mkdir -p "$VERSIONS_DIR"
fi

# Ensure __init__.py exists (for Python namespace)
touch "$VERSIONS_DIR/__init__.py"

# 3) Generate initial migration from models
echo "📝 Alembic: Generating new initial migration (autogenerate)..."
alembic -c "$ALEMBIC_INI" revision --autogenerate -m "Initial schema"

# 4) Apply migration to create schema in new DB
echo "🚀 Alembic: Upgrading database to head..."
alembic -c "$ALEMBIC_INI" upgrade head

echo
echo "✅ All done!"
echo "  • DB now at: $DB_FILE"
echo "  • Alembic migration in: $VERSIONS_DIR"
echo
echo "You can verify tables with:"
echo "  sqlite3 $DB_FILE '.tables'"
echo
echo "Safe to run tests or start dev API."
