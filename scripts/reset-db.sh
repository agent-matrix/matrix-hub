#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Matrix Hub FULL RESET Script (DB + Alembic)
#
# => Deletes both the catalog.sqlite and all Alembic migrations.
# => Rebuilds them from your current models.
#
# ⚠️ DESTRUCTIVE. Only run if you really want to start over from zero.
# ==============================================================================

# Resolve project root (script lives in scripts/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." &>/dev/null && pwd)"

# Paths
DB_FILE="$PROJECT_ROOT/data/catalog.sqlite"
VERSIONS_DIR="$PROJECT_ROOT/alembic/versions"
ALEMBIC_INI="$PROJECT_ROOT/alembic.ini"

echo ""
echo "🚨 YOU ARE ABOUT TO COMPLETELY RESET:"
echo "    • Database file:      $DB_FILE"
echo "    • Alembic versions:   $VERSIONS_DIR"
echo ""
read -p "Proceed? This will DELETE everything above. (y/N) " -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Aborting."
  exit 1
fi

cd "$PROJECT_ROOT"

# 1) Delete the SQLite DB file
if [[ -f "$DB_FILE" ]]; then
  echo "🗑️  Removing database file..."
  rm -f "$DB_FILE"
else
  echo "⚪ No DB file found; skipping."
fi

# 2) Delete all Alembic versions
if [[ -d "$VERSIONS_DIR" ]]; then
  echo "🗑️  Removing old migrations..."
  rm -rf "$VERSIONS_DIR"
else
  echo "⚪ No migrations directory found; skipping."
fi

# 3) Recreate empty versions dir
echo "✨ Recreating migrations folder..."
mkdir -p "$VERSIONS_DIR"
touch "$VERSIONS_DIR/__init__.py"
echo "   ✔ $VERSIONS_DIR ready."

# 4) Generate a fresh initial migration
echo "📝 Autogenerating initial schema migration..."
alembic -c "$ALEMBIC_INI" revision --autogenerate -m "Initial schema"

# 5) Stamp the database at 'base' so Alembic doesn't look for old revisions
#    (This creates the alembic_version table with the empty/base state.)
echo "🔖 Stamping database to 'base' revision..."
alembic -c "$ALEMBIC_INI" stamp base

# 6) Apply the new migration to build your schema
echo "🚀 Upgrading database to head..."
alembic -c "$ALEMBIC_INI" upgrade head

echo ""
echo "🎉 Reset complete! Fresh DB at $DB_FILE and migrations in $VERSIONS_DIR."
