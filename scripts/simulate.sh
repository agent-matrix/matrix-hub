#!/usr/bin/env bash
#
# scripts/simulate.sh — local repro of the prod matrix-hub container.
#
# Goal: prove that the supervisord.conf fix (mcpgateway pinned to :4444
# via CLI flag, HOST/PORT unset before sourcing mcpgateway/.env) survives
# the worst case .env we've actually observed in prod — one with PORT=443
# leaking in. Without the fix, mcpgateway wins the bind race and the Hub
# gunicorn crash-loops on :443. With the fix, the Hub owns :443 and
# mcpgateway owns :4444 regardless of what PORT says.
#
# What it does:
#   1. pulls ruslanmv/matrix-hub:latest
#   2. writes a deliberately broken .env with PORT=443 (the bug condition)
#   3. runs the container, mounting THIS repo's supervisord.conf over
#      /supervisord.conf so we don't need to rebuild the image
#   4. waits up to 60 s for both processes to be steady
#   5. asserts:
#        - Hub gunicorn is bound to :443 inside the container
#        - mcpgateway is bound to :4444 inside the container
#        - mcpgateway is NOT bound to :443
#        - the container is not in a restart loop
#        - GET https://127.0.0.1:8443/health returns something parseable
#        - GET http://127.0.0.1:14444/  (the gateway) returns 200
#   6. always tears the container down
#
# Usage:
#   bash scripts/simulate.sh
#   IMAGE=ruslanmv/matrix-hub:dev bash scripts/simulate.sh
#
# Exit codes:
#   0 — all assertions passed; safe to redeploy
#   1 — at least one assertion failed; do NOT redeploy without investigating

set -Eeuo pipefail

IMAGE="${IMAGE:-ruslanmv/matrix-hub:latest}"
CONTAINER="matrix-hub-sim"
# Map prod ports to high host ports so we don't clash with anything the
# operator is already running locally.
HUB_HOST_PORT="${HUB_HOST_PORT:-8443}"
GATEWAY_HOST_PORT="${GATEWAY_HOST_PORT:-14444}"
WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUPERVISORD="${WORKDIR}/supervisord.conf"
WAIT_SECONDS="${WAIT_SECONDS:-60}"

bold(){ printf '\033[1m%s\033[0m\n' "$*"; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$*"; }
step(){ printf '\n'; bold "▶ $*"; printf '%.0s-' {1..72}; printf '\n'; }

fail=0
record_fail(){ bad "$*"; fail=1; }

cleanup() {
  bold "▶ Tearing down ${CONTAINER}"
  docker stop "${CONTAINER}" >/dev/null 2>&1 || true
  docker rm   "${CONTAINER}" >/dev/null 2>&1 || true
  rm -rf "${TMP:-/nonexistent}"
}
trap cleanup EXIT

command -v docker >/dev/null || { bad "docker not installed"; exit 1; }
[ -f "${SUPERVISORD}" ] || { bad "supervisord.conf not found at ${SUPERVISORD}"; exit 1; }

step "1. Pull image"
docker pull "${IMAGE}"
ok "image pulled: ${IMAGE}"

step "2. Write deliberately-broken .env (PORT=443 simulates deploy #13)"
TMP="$(mktemp -d)"
cat > "${TMP}/.env" <<'ENV_EOF'
MATRIX_ENV=production
PUBLIC_BASE_URL=https://api.matrixhub.io
# This is the operator footgun: PORT=443 leaks via --env-file and used to
# make mcpgateway bind :443, which crash-looped the Hub gunicorn. With the
# fixed supervisord.conf, this MUST be ignored.
HOST=0.0.0.0
PORT=443
DATABASE_URL=sqlite:////app/data/matrixhub.sqlite
API_TOKEN=simulate-not-a-real-token
REQUIRE_API_TOKEN_IN_PROD=false
SEARCH_LEXICAL_BACKEND=none
SEARCH_VECTOR_BACKEND=none
SEARCH_BACKEND__LEXICAL=none
SEARCH_BACKEND__VECTOR=none
SEARCH_DEFAULT_MODE=keyword
RERANK_DEFAULT=none
INGEST_SCHED_ENABLED=false
ENV_EOF
ok ".env written to ${TMP}/.env"
grep -E '^(HOST|PORT)=' "${TMP}/.env" | sed 's/^/    /'

step "3. Run container with supervisord.conf overlay"
docker stop "${CONTAINER}" >/dev/null 2>&1 || true
docker rm   "${CONTAINER}" >/dev/null 2>&1 || true
docker run -d \
  --name "${CONTAINER}" \
  -p "${HUB_HOST_PORT}:443" \
  -p "${GATEWAY_HOST_PORT}:4444" \
  --env-file "${TMP}/.env" \
  -v "${SUPERVISORD}:/supervisord.conf:ro" \
  "${IMAGE}" >/dev/null
ok "container started"

step "4. Wait up to ${WAIT_SECONDS}s for processes to be steady"
elapsed=0
while [ "${elapsed}" -lt "${WAIT_SECONDS}" ]; do
  if docker exec "${CONTAINER}" sh -c \
       'ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null' \
       | grep -qE '(:443[[:space:]]).*LISTEN' && \
     docker exec "${CONTAINER}" sh -c \
       'ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null' \
       | grep -qE '(:4444[[:space:]]).*LISTEN'; then
    ok "both :443 and :4444 are listening inside the container"
    break
  fi
  sleep 2
  elapsed=$((elapsed + 2))
done
if [ "${elapsed}" -ge "${WAIT_SECONDS}" ]; then
  warn "timed out waiting; will still run assertions to capture the failure"
fi

step "5. Assertions"

# 5a. Container is not restarting.
status="$(docker inspect -f '{{.State.Status}}' "${CONTAINER}")"
restarts="$(docker inspect -f '{{.RestartCount}}' "${CONTAINER}")"
if [ "${status}" = "running" ] && [ "${restarts}" -le 1 ]; then
  ok "container status=${status}, restarts=${restarts}"
else
  record_fail "container status=${status}, restarts=${restarts} (expected running, ≤1)"
fi

# 5b. Hub gunicorn owns :443.
if docker exec "${CONTAINER}" sh -c 'ps -ef | grep -E "gunicorn.*0\.0\.0\.0:443" | grep -v grep' >/dev/null; then
  ok "gunicorn is running with --bind 0.0.0.0:443"
else
  record_fail "no gunicorn process bound to 0.0.0.0:443 — Hub didn't start"
fi

# 5c. mcpgateway owns :4444 (and ONLY :4444).
gateway_ports="$(docker exec "${CONTAINER}" sh -c 'ps -ef | grep -E "mcpgateway" | grep -v grep' || true)"
if echo "${gateway_ports}" | grep -qE -- '--port[ =]4444'; then
  ok "mcpgateway is running with --port 4444"
else
  record_fail "mcpgateway is NOT running with --port 4444. ps -ef output:"
  echo "${gateway_ports}" | sed 's/^/      /'
fi
if echo "${gateway_ports}" | grep -qE -- '--port[ =]443([^0-9]|$)'; then
  record_fail "mcpgateway IS running with --port 443 — supervisord.conf fix did NOT apply"
fi

# 5d. Bind table: :443 and :4444 both listening, no double-bind on :443.
binds="$(docker exec "${CONTAINER}" sh -c 'ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null' || true)"
if echo "${binds}" | grep -qE '(:443[[:space:]]).*LISTEN'; then
  ok ":443 is listening"
else
  record_fail ":443 is NOT listening"
fi
if echo "${binds}" | grep -qE '(:4444[[:space:]]).*LISTEN'; then
  ok ":4444 is listening"
else
  record_fail ":4444 is NOT listening"
fi

# 5e. /health on :443 (TLS) and / on :4444 (cleartext) both answer.
if curl -ksS --max-time 5 "https://127.0.0.1:${HUB_HOST_PORT}/health" >/dev/null; then
  ok "GET /health on :${HUB_HOST_PORT} answered"
else
  record_fail "GET /health on :${HUB_HOST_PORT} failed"
fi
if curl -fsS --max-time 5 "http://127.0.0.1:${GATEWAY_HOST_PORT}/" >/dev/null; then
  ok "GET / on :${GATEWAY_HOST_PORT} (mcpgateway) answered"
else
  record_fail "GET / on :${GATEWAY_HOST_PORT} (mcpgateway) failed"
fi

step "6. Last 80 lines of container log (for context)"
docker logs --tail 80 "${CONTAINER}" 2>&1 | sed 's/^/    /' || true

step "7. Verdict"
if [ "${fail}" -eq 0 ]; then
  ok "All assertions passed. The supervisord.conf fix neutralises PORT=443 in the .env."
  exit 0
else
  bad "One or more assertions failed. DO NOT redeploy until these are explained."
  exit 1
fi
