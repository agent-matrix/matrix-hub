#!/usr/bin/env bash
# scripts/init_alembic.sh
# Initialize Alembic migrations for Matrix Hub (local SQLite by default).
# - Ensures venv + alembic available
# - Verifies import path shim for alembic/env.py (src.* import)
# - Creates ./data folder and DATABASE_URL if missing
# - Creates an initial migration only if none exist; otherwise upgrades DB
# - Optional quick verification and health check instructions
#
# Usage:
#   bash scripts/init_alembic.sh
#   DATABASE_URL="postgresql+psycopg://user:pass@localhost/db" bash scripts/init_alembic.sh
#
# Flags (env):
#   MSG                Migration message (default: "initial schema")
#   SKIP_VERIFY=1      Skip sqlite quick verification step
#   NO_RUN=1           Do not print run instructions at the end

set -Eeuo pipefail
trap 'echo "❌ Error on line $LINENO"; exit 1' ERR

# --------------------------- helpers ---------------------------
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${here}/.." && pwd)"

echo "▶ Matrix Hub — Alembic initialization"
echo "  ROOT: ${root}"

# cd to project root so relative paths work
cd "$root"

# --------------------------- 0) One-time checks ---------------------------
echo "→ Step 0: One-time checks"

# Ensure src/models.py exists
if [[ ! -f "${root}/src/models.py" ]]; then
  echo "❌ src/models.py not found. Please create your ORM models before running migrations."
  exit 1
fi

# Ensure alembic/env.py has a sys.path shim line (best-effort check)
if ! grep -q "PROJECT_ROOT" "${root}/alembic/env.py"; then
  cat <<'EOWARN'
⚠️  Warning: alembic/env.py does not appear to include a PYTHONPATH/project-root shim.
    Make sure the top of alembic/env.py contains something like:

    from pathlib import Path
    import sys
    PROJECT_ROOT = Path(__file__).resolve().parents[1]
    if str(PROJECT_ROOT) not in sys.path:
        sys.path.insert(0, str(PROJECT_ROOT))

EOWARN
fi

# --------------------------- ensure venv/alembic ---------------------------
echo "→ Checking virtualenv & alembic"

if [[ -d ".venv" ]]; then
  # shellcheck disable=SC1091
  source .venv/bin/activate
fi

if ! command -v alembic >/dev/null 2>&1; then
  echo "ℹ️  alembic not found, installing dev deps into venv…"
  python3 -m venv .venv
  # shellcheck disable=SC1091
  source .venv/bin/activate
  python -m pip install -U pip
  pip install -e .[dev]
fi

echo "   using alembic: $(command -v alembic)"

# --------------------------- 1) DB URL & folders ---------------------------
echo "→ Step 1: Set database URL & folders"

DEFAULT_SQLITE_URL="sqlite+pysqlite:///./data/catalog.sqlite"
if [[ -f ".env" ]]; then
  # shellcheck disable=SC2046
  set -a; . .env; set +a
fi

if [[ -z "${DATABASE_URL:-}" ]]; then
  echo "   DATABASE_URL not set; using local SQLite at ${DEFAULT_SQLITE_URL}"
  export DATABASE_URL="${DEFAULT_SQLITE_URL}"
else
  echo "   DATABASE_URL=${DATABASE_URL}"
fi

# Create ./data folder for sqlite path if needed
if [[ "${DATABASE_URL}" == sqlite* ]]; then
  mkdir -p ./data
fi

# --------------------------- 2) Create/ensure migrations --------------------
echo "→ Step 2: Ensure migrations are consistent"

# Determine if we already have revisions in the repo
have_versions=0
if [ -d "alembic/versions" ] && ls -1q alembic/versions/*.py >/dev/null 2>&1; then
  have_versions=1
fi

# Check DB status relative to head
set +e
DB_CURRENT="$(alembic current 2>/dev/null | tail -n1 | awk '{print $1}')"
DB_HEADS="$(alembic heads 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
set -e

if [ -n "$DB_HEADS" ]; then
  # If there are heads in code and DB isn't at head, upgrade first
  if ! alembic current >/dev/null 2>&1; then
    echo "→ Database has no revision marker; upgrading to head…"
    alembic upgrade head
  else
    if ! alembic current | grep -q "(head)"; then
      echo "→ Database is not at head; upgrading…"
      alembic upgrade head
    else
      echo "→ Database is already at head."
    fi
  fi
fi

if [ "$have_versions" -eq 0 ]; then
  echo "→ No existing revisions found; creating initial migration (autogenerate)…"
  MSG="${MSG:-initial schema}"
  alembic revision --autogenerate -m "${MSG}" || {
    echo "❌ alembic revision failed. Ensure 'from src.models import Base' exposes your models."
    exit 1
  }
  echo "→ Applying initial migration…"
  alembic upgrade head
else
  echo "→ Revisions already exist; skipping autogenerate."
fi

# --------------------------- Quick verify (optional) ------------------------
if [[ "${SKIP_VERIFY:-0}" != "1" && "${DATABASE_URL}" == sqlite* ]]; then
  if command -v sqlite3 >/dev/null 2>&1; then
    sqlite_path="$(python - <<'PY'
import os
url = os.environ.get("DATABASE_URL","")
# naive extraction: sqlite+pysqlite:///./data/catalog.sqlite -> ./data/catalog.sqlite
if url.startswith("sqlite"):
    print(url.split("///",1)[-1])
PY
)"
    if [[ -n "${sqlite_path}" && -f "${sqlite_path}" ]]; then
      echo "→ Verifying tables in ${sqlite_path}"
      sqlite3 "${sqlite_path}" '.tables' || true
    else
      echo "⚠️  Could not locate sqlite file for quick verification."
    fi
  else
    echo "ℹ️  sqlite3 CLI not found; skipping quick verification."
  fi
fi

# --------------------------- 4) Run instructions ----------------------------
if [[ "${NO_RUN:-0}" != "1" ]]; then
  cat <<'EONOTE'

→ Step 4: Run the API (choose one)

  uvicorn src.app:app --reload --port 443
  # or
  make dev

Health check (DB ping):
  curl 'http://127.0.0.1:443/health?check_db=true'

EONOTE
fi

echo "✅ Alembic initialization complete."
