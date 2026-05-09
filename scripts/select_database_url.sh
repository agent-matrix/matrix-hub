#!/usr/bin/env bash
#
# scripts/select_database_url.sh
#
# Pick the working DATABASE_URL at container startup.
#
# Strategy:
#   1. If $DATABASE_URL is set explicitly, it wins (no probing).
#   2. Otherwise, try $DATABASE_URL_PRIMARY first.
#   3. Fall back to $DATABASE_URL_FALLBACK if the primary is unreachable.
#   4. If neither answers, exit non-zero so the container fails fast.
#
# IMPORTANT: this is a *startup-time* selector. SQLAlchemy will not
# automatically failover between databases at runtime — if Aiven goes
# down mid-flight the Hub will crash (and the orchestrator will restart
# it, at which point this script will pick the fallback if needed).
#
# Source this script from docker-entrypoint.sh BEFORE starting Gunicorn:
#
#   # docker-entrypoint.sh
#   . /app/scripts/select_database_url.sh
#   export DATABASE_URL
#   exec gunicorn ...
#
# Usage knobs:
#   PROBE_TIMEOUT=5         # seconds per psql probe (default 5)
#   PROBE_RETRIES=2         # retry each URL N times (default 2)
#   ON_FALLBACK=warn        # warn (default), require, or fail
#                           #   warn      → continue, emit ::warning::
#                           #   require   → continue but log loudly
#                           #   fail      → exit non-zero (production-strict)

set -u

PROBE_TIMEOUT="${PROBE_TIMEOUT:-5}"
PROBE_RETRIES="${PROBE_RETRIES:-2}"
ON_FALLBACK="${ON_FALLBACK:-warn}"

bold() { printf '\033[1m%s\033[0m\n' "$*" >&2; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*" >&2; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*" >&2; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; }
mask() { echo "$1" | sed -E 's#(://[^:]+:)[^@]+(@)#\1***\2#'; }

probe_one() {
  # $1 = libpq URL (postgresql://...) — SQLAlchemy URLs (postgresql+psycopg://) are normalised
  local url="$1"
  local libpq_url
  libpq_url="$(echo "$url" | sed -E 's#^postgresql\+(psycopg|asyncpg)://#postgresql://#')"
  PGCONNECT_TIMEOUT="$PROBE_TIMEOUT" psql "$libpq_url" -tAc 'SELECT 1' >/dev/null 2>&1
}

probe_with_retries() {
  local url="$1" i=0
  while [ "$i" -lt "$PROBE_RETRIES" ]; do
    if probe_one "$url"; then return 0; fi
    i=$((i+1))
    sleep 1
  done
  return 1
}

bold "▶ Selecting DATABASE_URL"

if [ -n "${DATABASE_URL:-}" ]; then
  ok "DATABASE_URL set explicitly — using it without probing: $(mask "$DATABASE_URL")"
  return 0 2>/dev/null || exit 0
fi

# psql is required for probing. If it's not in the image, just trust the primary.
if ! command -v psql >/dev/null 2>&1; then
  if [ -n "${DATABASE_URL_PRIMARY:-}" ]; then
    warn "psql not installed; cannot probe — defaulting to DATABASE_URL_PRIMARY"
    export DATABASE_URL="$DATABASE_URL_PRIMARY"
    return 0 2>/dev/null || exit 0
  else
    bad "psql not installed and DATABASE_URL_PRIMARY is unset — cannot continue"
    return 1 2>/dev/null || exit 1
  fi
fi

PRIMARY="${DATABASE_URL_PRIMARY:-}"
FALLBACK="${DATABASE_URL_FALLBACK:-}"

if [ -z "$PRIMARY" ] && [ -z "$FALLBACK" ]; then
  bad "neither DATABASE_URL nor DATABASE_URL_PRIMARY is set — cannot start"
  return 1 2>/dev/null || exit 1
fi

if [ -n "$PRIMARY" ]; then
  if probe_with_retries "$PRIMARY"; then
    ok "primary reachable: $(mask "$PRIMARY")"
    export DATABASE_URL="$PRIMARY"
    return 0 2>/dev/null || exit 0
  else
    warn "primary unreachable after $PROBE_RETRIES tries: $(mask "$PRIMARY")"
  fi
fi

if [ -n "$FALLBACK" ]; then
  if probe_with_retries "$FALLBACK"; then
    case "$ON_FALLBACK" in
      fail)
        bad "primary down and ON_FALLBACK=fail — refusing to start on stale fallback"
        return 1 2>/dev/null || exit 1
        ;;
      require|warn|*)
        echo "::warning::matrix-hub starting against FALLBACK DB. Reads/writes will diverge from primary; restore primary ASAP." >&2
        warn "falling back to: $(mask "$FALLBACK")"
        export DATABASE_URL="$FALLBACK"
        export MATRIXHUB_DB_USED="fallback"   # the app/healthcheck can surface this
        return 0 2>/dev/null || exit 0
        ;;
    esac
  else
    bad "fallback also unreachable: $(mask "$FALLBACK")"
  fi
fi

bad "no DATABASE_URL candidate is reachable — exiting"
return 1 2>/dev/null || exit 1
