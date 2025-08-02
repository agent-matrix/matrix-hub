#!/usr/bin/env bash
# scripts/check_alembic.sh
# Health check for Alembic + DB schema state.
#
# What it does:
#   - Ensures we're in project root and venv (if present)
#   - Loads .env (if present) and prints DATABASE_URL
#   - Verifies alembic is available and env.py has project-root shim
#   - Shows alembic heads/current and checks if DB is at head
#   - For SQLite: checks the DB file exists and (optionally) that `entity` table exists
#
# Exit codes:
#   0 = healthy
#   1 = one or more checks failed
#
# Usage:
#   bash scripts/check_alembic.sh
#   VERBOSE=1 bash scripts/check_alembic.sh
#   CHECK_ENTITY=1 bash scripts/check_alembic.sh    # also verify 'entity' table on SQLite

set -Eeuo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${here}/.." && pwd)"
cd "$root"

VERBOSE="${VERBOSE:-0}"
CHECK_ENTITY="${CHECK_ENTITY:-0}"

say() { printf "%b\n" "$*"; }
info() { say "ℹ️  $*"; }
ok()   { say "✅ $*"; }
warn() { say "⚠️  $*"; }
err()  { say "❌ $*" >&2; }

status_fail=0

say "▶ Alembic health check"
info "ROOT: ${root}"

# 1) Virtualenv / alembic
if [[ -d ".venv" ]]; then
  # shellcheck disable=SC1091
  source .venv/bin/activate || { err "Failed to activate .venv"; status_fail=1; }
fi

if ! command -v alembic >/dev/null 2>&1; then
  err "alembic not found in PATH. Activate your venv or install dev deps (pip install -e .[dev])."
  status_fail=1
else
  info "alembic: $(command -v alembic)"
fi

# 2) Load .env (optional)
if [[ -f ".env" ]]; then
  set -a; . ".env"; set +a
  info "Loaded .env"
else
  warn "No .env found at project root."
fi

DATABASE_URL="${DATABASE_URL:-}"
if [[ -z "$DATABASE_URL" ]]; then
  warn "DATABASE_URL is not set. Alembic may still read it from alembic.ini or env.py."
else
  info "DATABASE_URL=${DATABASE_URL}"
fi

# 3) env.py path shim
if [[ -f "alembic/env.py" ]]; then
  if grep -q "PROJECT_ROOT" "alembic/env.py"; then
    ok "alembic/env.py has project-root (PYTHONPATH) shim."
  else
    warn "alembic/env.py might be missing the project-root shim; imports like 'src.*' could fail."
  fi
else
  err "alembic/env.py not found."
  status_fail=1
fi

# 4) Alembic heads/current
HEADS_OUT="$(alembic heads 2>&1 || true)"
CURRENT_OUT="$(alembic current 2>&1 || true)"

if [[ "$VERBOSE" == "1" ]]; then
  say "---- alembic heads ----"
  say "$HEADS_OUT"
  say "---- alembic current ----"
  say "$CURRENT_OUT"
fi

# Parse states
have_heads=0
if echo "$HEADS_OUT" | grep -E '^[0-9a-f]+' >/dev/null 2>&1; then
  have_heads=1
fi

at_head=0
if echo "$CURRENT_OUT" | grep -q "(head)"; then
  at_head=1
fi

if [[ "$have_heads" -eq 0 ]]; then
  warn "No revision heads found (repository may not have any generated migrations yet)."
else
  ok "Alembic revision heads detected."
fi

# If there are heads, the DB should be at head for 'healthy' state.
if [[ "$have_heads" -eq 1 ]]; then
  if [[ "$at_head" -eq 1 ]]; then
    ok "Database is at head."
  else
    # current output can also indicate 'None' (no revision marker)
    if echo "$CURRENT_OUT" | grep -qi "None" ; then
      warn "Database has no revision marker (empty or uninitialized). Consider: alembic upgrade head."
    else
      err "Database is NOT at head. Run: alembic upgrade head"
      status_fail=1
    fi
  fi
fi

# 5) SQLite quick checks
sqlite_ok=1
sqlite_path=""
if [[ "${DATABASE_URL}" == sqlite:* ]]; then
  # Extract file path from sqlite URL
  sqlite_path="$(python - "$DATABASE_URL" <<'PY'
import os, sys
url = sys.argv[1]
# sqlite:///relative/path
# sqlite:////absolute/path
if url.startswith("sqlite"):
    # split after first '///'
    if "///" in url:
        p = url.split("///",1)[-1]
        # strip any query params if present
        p = p.split("?",1)[0]
        print(p)
PY
)"
  if [[ -n "$sqlite_path" ]]; then
    if [[ -f "$sqlite_path" ]]; then
      ok "SQLite file present: $sqlite_path"
      if command -v sqlite3 >/dev/null 2>&1; then
        if [[ "$VERBOSE" == "1" ]]; then
          info "SQLite tables:"
          sqlite3 "$sqlite_path" '.tables' || true
        fi
        if [[ "$CHECK_ENTITY" == "1" ]]; then
          if sqlite3 "$sqlite_path" ".schema entity" >/dev/null 2>&1; then
            ok "Table 'entity' exists in SQLite DB."
          else
            err "Table 'entity' not found in SQLite DB."
            sqlite_ok=0
          fi
        fi
      else
        warn "sqlite3 CLI not found; skipping table introspection."
      fi
    else
      err "SQLite file NOT found at: $sqlite_path  (Check working dir and DATABASE_URL path)."
      sqlite_ok=0
    fi
  else
    warn "Could not parse SQLite path from DATABASE_URL."
  fi
fi

if [[ "$sqlite_ok" -eq 0 ]]; then
  status_fail=1
fi

# Summary
if [[ "$status_fail" -eq 0 ]]; then
  ok "Alembic / DB check: HEALTHY"
  exit 0
else
  err "Alembic / DB check: UNHEALTHY — see messages above."
  exit 1
fi
