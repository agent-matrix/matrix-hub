#!/usr/bin/env bash
#
# diagnosis.sh — read-only health probe for the Matrix Hub backend.
#
# Run on the Ubuntu host where matrix-hub is deployed. Makes no
# changes; just inspects state and prints a numbered report so you
# can paste it back for review.
#
# Usage:
#   bash scripts/diagnosis.sh
#   CONTAINER_NAME=matrixhub DB_PRIVATE_IP=10.0.0.185 bash scripts/diagnosis.sh

set -u

CONTAINER_NAME="${CONTAINER_NAME:-matrixhub}"
DB_PRIVATE_IP="${DB_PRIVATE_IP:-10.0.0.185}"
DB_PORT="${DB_PORT:-5432}"
HUB_LOCAL_URL="${HUB_LOCAL_URL:-https://127.0.0.1:443}"
PUBLIC_HUB_URL="${PUBLIC_HUB_URL:-https://api.matrixhub.io}"
ENV_FILE="${ENV_FILE:-.env}"

# ---------- pretty helpers ----------
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }
hr()     { printf '%.0s-' {1..72}; printf '\n'; }
section(){ printf '\n'; bold "=== $* ==="; hr; }
ok()     { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn()   { printf '  \033[33m!\033[0m %s\n' "$*"; }
bad()    { printf '  \033[31m✗\033[0m %s\n' "$*"; }
info()   { printf '    %s\n' "$*"; }

run() {
  local label="$1"; shift
  printf '\n  $ %s\n' "$*"
  "$@" 2>&1 | sed 's/^/    /'
  printf '    [exit=%d]\n' "${PIPESTATUS[0]}"
}

# ---------- 0. host & tools ----------
section "0. Host"
run "uname"       uname -a
run "uptime"      uptime
run "whoami"      whoami
for t in docker curl ss psql nc free df; do
  if command -v "$t" >/dev/null 2>&1; then
    ok  "$t found at $(command -v "$t")"
  else
    warn "$t NOT installed (some checks will be skipped)"
  fi
done

# ---------- 1. memory & disk ----------
section "1. Memory & disk"
run "free -h" free -h
run "df -h /" df -h /
run "swap status" swapon --show

# ---------- 2. container ----------
section "2. Container '${CONTAINER_NAME}'"
if ! command -v docker >/dev/null 2>&1; then
  bad "docker not installed — skipping container checks"
else
  if docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
    ok "container exists"
    run "docker ps -a (filtered)" docker ps -a --filter "name=^/${CONTAINER_NAME}$" \
      --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Image}}'
    if docker ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
      ok "container is running"
    else
      bad "container is NOT running"
    fi
    run "docker stats (1 sample)" docker stats --no-stream "${CONTAINER_NAME}"
    run "mounts (host paths bound in)" \
      bash -c "docker inspect '${CONTAINER_NAME}' --format '{{json .HostConfig.Binds}}' | tr ',' '\n'"
    run "restart policy" \
      bash -c "docker inspect '${CONTAINER_NAME}' --format '{{json .HostConfig.RestartPolicy}}'"
  else
    bad "container '${CONTAINER_NAME}' does not exist"
  fi
fi

# ---------- 3. effective env inside the container ----------
section "3. Effective env inside the container"
if docker ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}" 2>/dev/null; then
  printf '  (Looking for DATABASE_URL, PUBLIC_BASE_URL, API_TOKEN, MATRIX_ENV, HOST, PORT, SEARCH_*)\n'
  # Don't leak full secrets — mask the password portion of DATABASE_URL.
  docker exec "${CONTAINER_NAME}" printenv 2>/dev/null \
    | grep -E '^(DATABASE_URL|PUBLIC_BASE_URL|API_TOKEN|MATRIX_ENV|HOST|PORT|SEARCH_|CATALOG_|INGEST_|REQUIRE_API_TOKEN_IN_PROD|CORS_)' \
    | sed -E 's#(DATABASE_URL=[^:]+://[^:]+:)[^@]+(@.*)#\1***\2#; s#(API_TOKEN=).{4,}#\1***#' \
    | sed 's/^/    /' \
    || warn "couldn't read env from container"
else
  warn "container not running — skipping"
fi

# ---------- 4. .env on disk ----------
section "4. .env on disk"
if [ -f "${ENV_FILE}" ]; then
  ok "${ENV_FILE} exists"
  printf '  (relevant keys, password masked)\n'
  grep -E '^(DATABASE_URL|PUBLIC_BASE_URL|API_TOKEN|MATRIX_ENV|HOST|PORT|SEARCH_|CATALOG_|INGEST_|REQUIRE_API_TOKEN_IN_PROD|CORS_)' "${ENV_FILE}" \
    | sed -E 's#(DATABASE_URL=[^:]+://[^:]+:)[^@]+(@.*)#\1***\2#; s#(API_TOKEN=).{4,}#\1***#' \
    | sed 's/^/    /' \
    || warn "no relevant keys found"
else
  bad "${ENV_FILE} NOT found at $(pwd)/${ENV_FILE}"
fi

# ---------- 5. listening ports ----------
section "5. Host listening ports"
if command -v ss >/dev/null 2>&1; then
  printf '  (sudo may prompt to show process names)\n'
  run "ss -ltnp filter 80/443/4444/5432" \
    bash -c "sudo -n ss -ltnp 2>/dev/null | grep -E ':(80|443|4444|5432)' || ss -ltn | grep -E ':(80|443|4444|5432)'"
else
  warn "ss not available"
fi

# ---------- 6. local Hub liveness ----------
section "6. Local Hub liveness (${HUB_LOCAL_URL})"
if command -v curl >/dev/null 2>&1; then
  run "GET /health?check_db=true" \
    curl -ksS -o /tmp/_diag_health.json -w 'HTTP %{http_code} (%{time_total}s)\n' \
      --max-time 8 "${HUB_LOCAL_URL}/health?check_db=true"
  if [ -s /tmp/_diag_health.json ]; then
    info "body:"
    sed 's/^/      /' /tmp/_diag_health.json | head -c 600
    printf '\n'
  fi
  run "GET /catalog?limit=1" \
    curl -ksS -o /tmp/_diag_cat.json -w 'HTTP %{http_code} (%{time_total}s)\n' \
      --max-time 8 "${HUB_LOCAL_URL}/catalog?limit=1"
else
  warn "curl not available"
fi

# ---------- 7. database reachability from this host ----------
section "7. Database reachability ${DB_PRIVATE_IP}:${DB_PORT}"
if command -v nc >/dev/null 2>&1; then
  run "nc -vz" timeout 5 nc -vz "${DB_PRIVATE_IP}" "${DB_PORT}"
else
  warn "nc not installed (apt-get install -y netcat-openbsd)"
fi
if command -v psql >/dev/null 2>&1; then
  if [ -f "${ENV_FILE}" ]; then
    DBURL="$(grep -E '^DATABASE_URL=' "${ENV_FILE}" | head -n1 | cut -d= -f2- | tr -d '\r' )"
    if [ -n "${DBURL}" ]; then
      # psql understands postgres:// not postgresql+psycopg://
      PSQL_URL="$(echo "${DBURL}" | sed 's#^postgresql+psycopg://#postgresql://#; s#^postgresql+asyncpg://#postgresql://#')"
      run "psql connectivity (\\dt)" \
        bash -c "PGCONNECT_TIMEOUT=5 psql '${PSQL_URL}' -c '\\dt' 2>&1 | head -n 30"
    else
      warn "DATABASE_URL not in .env, skipping psql probe"
    fi
  fi
else
  warn "psql not installed (apt-get install -y postgresql-client)"
fi

# ---------- 8. recent container logs ----------
section "8. Recent logs (last 60 lines)"
if docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}" 2>/dev/null; then
  printf '  (filtered for ERROR / SIGKILL / sqlite / postgres / DATABASE / startup)\n'
  docker logs --tail 200 "${CONTAINER_NAME}" 2>&1 \
    | grep -iE 'error|sigkill|oom|sqlite|postgres|psycopg|alembic|database|listening|started server|exited with code|booting worker|startup' \
    | tail -n 60 \
    | sed 's/^/    /' \
    || warn "no logs"
else
  warn "container not present — skipping"
fi

# ---------- 9. inside-container log files ----------
section "9. Log files inside the container"
if docker ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}" 2>/dev/null; then
  run "ls /app/logs" \
    docker exec "${CONTAINER_NAME}" sh -c 'ls -la /app/logs 2>/dev/null || echo "(no /app/logs)"'
  run "tail -n 40 /app/logs/*.log" \
    docker exec "${CONTAINER_NAME}" sh -c 'tail -n 40 /app/logs/*.log 2>/dev/null || echo "(no log files)"'
else
  warn "container not running — skipping"
fi

# ---------- 10. public reachability ----------
section "10. Public reachability ${PUBLIC_HUB_URL}"
if command -v curl >/dev/null 2>&1; then
  run "GET /health?check_db=true" \
    curl -sS -o /tmp/_diag_pub_health.json -w 'HTTP %{http_code} (%{time_total}s)\n' \
      --max-time 8 "${PUBLIC_HUB_URL}/health?check_db=true"
  if [ -s /tmp/_diag_pub_health.json ]; then
    info "body:"; sed 's/^/      /' /tmp/_diag_pub_health.json | head -c 400; printf '\n'
  fi
  run "GET /catalog?limit=1" \
    curl -sS -o /dev/null -w 'HTTP %{http_code} (%{time_total}s)\n' \
      --max-time 8 "${PUBLIC_HUB_URL}/catalog?limit=1"
fi

# ---------- 11. summary heuristics ----------
section "11. Heuristics"

heur=()
if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${CONTAINER_NAME}"; then
  heur+=("container is not running → start it (scripts/run_container.sh) and re-check.")
fi
if [ -f "${ENV_FILE}" ] && ! grep -qE '^DATABASE_URL=postgres' "${ENV_FILE}"; then
  heur+=("DATABASE_URL in .env is missing or not pointing at Postgres → Hub will fall back to SQLite.")
fi
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${CONTAINER_NAME}"; then
  if ! docker exec "${CONTAINER_NAME}" printenv DATABASE_URL >/dev/null 2>&1; then
    heur+=(".env is not reaching the container → check the volume mount in run_container.sh.")
  fi
fi
if docker logs --tail 200 "${CONTAINER_NAME}" 2>&1 | grep -q 'SIGKILL'; then
  heur+=("workers are being SIGKILL'd (OOM) → add swap and/or reduce gunicorn workers to 1.")
fi
if docker logs --tail 200 "${CONTAINER_NAME}" 2>&1 | grep -q 'SQLiteImpl'; then
  heur+=("Alembic ran against SQLite — DATABASE_URL is not being honoured.")
fi
if [ "${#heur[@]}" -eq 0 ]; then
  ok "No automated red flags found. Look at sections 6, 8 and 10 to confirm health."
else
  for h in "${heur[@]}"; do warn "$h"; done
fi

printf '\n'
bold "Done. Paste sections 1–11 back to your reviewer."
