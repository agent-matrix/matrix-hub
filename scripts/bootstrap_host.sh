#!/usr/bin/env bash
#
# scripts/bootstrap_host.sh
#
# One-stop, interactive first-time setup for a fresh Ubuntu OCI VM that
# will run the matrix-hub backend. Walks through:
#
#   1. Docker CE             (scripts/install_docker_ubuntu.sh)
#   2. TLS certificate       (scripts/install_certificate.sh, optional)
#   3. .env from .env.example (interactive edit)
#   4. Build the image       (scripts/build_container.sh)
#   5. Start the container   (scripts/run_container.sh)
#   6. Health probe          (https://127.0.0.1:443/health?check_db=true)
#
# Idempotent: every step checks state first and skips when possible.
# Read-only by default until you confirm with "y" at each destructive step.
#
# Usage:
#   bash scripts/bootstrap_host.sh           # interactive
#   AUTO=1 bash scripts/bootstrap_host.sh    # answer YES to every prompt
#
# Env knobs:
#   SKIP_DOCKER=1       skip step 1
#   SKIP_CERT=1         skip step 2
#   SKIP_ENV=1          skip step 3
#   SKIP_BUILD=1        skip step 4
#   SKIP_RUN=1          skip step 5
#   HEALTH_TIMEOUT=120  seconds to wait for /health to return 200

set -Eeuo pipefail

AUTO="${AUTO:-0}"
HEALTH_URL="${HEALTH_URL:-https://127.0.0.1:443/health?check_db=true}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-120}"

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
ok()    { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn()  { printf '  \033[33m!\033[0m %s\n' "$*"; }
bad()   { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; }
info()  { printf '    %s\n' "$*"; }
hr()    { printf '%.0s-' {1..72}; printf '\n'; }
step()  { printf '\n'; bold "▶ $*"; hr; }

confirm() {
  local prompt="$1" default="${2:-n}" reply
  if [ "$AUTO" = "1" ]; then
    info "AUTO=1 → answering YES to: $prompt"
    return 0
  fi
  local hint="[y/N]"; [ "$default" = "y" ] && hint="[Y/n]"
  read -r -p "  $prompt $hint " reply || reply=""
  reply="${reply:-$default}"
  case "$reply" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

trap 'bad "bootstrap_host.sh aborted on line $LINENO"' ERR

# --- preflight ---
[ -d .git ]   || { bad "run from the matrix-hub repo root"; exit 1; }
[ -d scripts ] || { bad "no ./scripts directory found"; exit 1; }

step "0. System summary"
. /etc/os-release 2>/dev/null || true
info "OS:       ${PRETTY_NAME:-?}"
info "kernel:   $(uname -r)"
info "user:     ${SUDO_USER:-$USER}"
info "pwd:      $(pwd)"
info "branch:   $(git symbolic-ref --quiet --short HEAD || git rev-parse --short HEAD)"

# --- 1. docker ---
if [ "${SKIP_DOCKER:-0}" = "1" ]; then
  step "1. Docker — SKIP_DOCKER=1, skipping"
elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  step "1. Docker — already installed and running"
  ok "$(docker --version)"
else
  step "1. Docker"
  if confirm "Install Docker CE via scripts/install_docker_ubuntu.sh?" "y"; then
    bash scripts/install_docker_ubuntu.sh
  else
    info "skipped."
  fi
fi

# --- 2. cert ---
if [ "${SKIP_CERT:-0}" = "1" ]; then
  step "2. TLS certificate — SKIP_CERT=1, skipping"
elif [ -s /etc/ssl/matrixhub/cf-origin.pem ] && [ -s /etc/ssl/matrixhub/cf-origin.key ]; then
  step "2. TLS certificate — already installed"
  ok "$(ls -l /etc/ssl/matrixhub/cf-origin.* 2>/dev/null | head -n 2 | sed 's/^/      /')"
else
  step "2. TLS certificate"
  if [ -f cf-origin.pem ] && [ -f cf-origin.key ]; then
    info "found ./cf-origin.pem and ./cf-origin.key in the current directory"
    if confirm "Install them to /etc/ssl/matrixhub via scripts/install_certificate.sh?" "y"; then
      bash scripts/install_certificate.sh
    else
      info "skipped."
    fi
  else
    warn "no cf-origin.pem/cf-origin.key in $(pwd)"
    info "Upload them from your laptop, e.g.:"
    info "  scp cf-origin.{pem,key} ${SUDO_USER:-$USER}@<this-host>:~/matrix-hub/"
    info "Then re-run this script (or 'bash scripts/install_certificate.sh' directly)."
    if ! confirm "Continue without TLS certificate?" "n"; then
      info "aborted."; exit 0
    fi
  fi
fi

# --- 3. .env ---
if [ "${SKIP_ENV:-0}" = "1" ]; then
  step "3. .env — SKIP_ENV=1, skipping"
elif [ -f .env ]; then
  step "3. .env — already exists"
  ok "$(ls -l .env | sed 's/^/      /')"
  if grep -qE '^DATABASE_URL=postgres' .env; then
    ok "DATABASE_URL points to Postgres"
  else
    warn "DATABASE_URL is not set to a postgres URL — Hub will fall back to SQLite."
    if confirm "Open .env in \$EDITOR now?" "y"; then
      "${EDITOR:-nano}" .env
    fi
  fi
else
  step "3. .env"
  if [ -f .env.example ]; then
    cp .env.example .env
    ok "created .env from .env.example"
    warn "Edit .env now — at minimum, set DATABASE_URL, API_TOKEN, PUBLIC_BASE_URL."
    if confirm "Open .env in \$EDITOR now?" "y"; then
      "${EDITOR:-nano}" .env
    fi
  else
    bad ".env.example not found in $(pwd)"
    exit 1
  fi
fi

# --- 4. build ---
if [ "${SKIP_BUILD:-0}" = "1" ]; then
  step "4. Build — SKIP_BUILD=1, skipping"
elif [ -x scripts/build_container.sh ]; then
  step "4. Build the image"
  if confirm "Run scripts/build_container.sh now?" "y"; then
    bash scripts/build_container.sh
    ok "build complete"
  else
    info "skipped — re-run later: bash scripts/build_container.sh"
  fi
else
  step "4. Build — scripts/build_container.sh not found, skipping"
fi

# --- 5. run ---
if [ "${SKIP_RUN:-0}" = "1" ]; then
  step "5. Run — SKIP_RUN=1, skipping"
elif [ -x scripts/run_container.sh ]; then
  step "5. Start the container"
  if confirm "Run scripts/run_container.sh now?" "y"; then
    bash scripts/run_container.sh
    ok "container started"
  else
    info "skipped — re-run later: bash scripts/run_container.sh"
  fi
else
  step "5. Run — scripts/run_container.sh not found, skipping"
fi

# --- 6. health ---
step "6. Health probe ($HEALTH_URL, up to ${HEALTH_TIMEOUT}s)"
if ! command -v curl >/dev/null 2>&1; then
  warn "curl not installed — skipping"
else
  deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
  healthy=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    status="$(curl -ksS -o /tmp/_boot_health.json -w '%{http_code}' --max-time 5 "$HEALTH_URL" || echo 000)"
    body="$(head -c 200 /tmp/_boot_health.json 2>/dev/null || true)"
    if [ "$status" = "200" ] && echo "$body" | grep -q '"db"[[:space:]]*:[[:space:]]*"ok"'; then
      ok "/health 200 with db=ok"
      info "body: $body"
      healthy=1; break
    fi
    printf '    waiting… HTTP %s, body=%s\n' "$status" "${body:0:80}"
    sleep 5
  done
  [ "$healthy" = "1" ] || warn "Hub did not become healthy in ${HEALTH_TIMEOUT}s — check 'docker logs -f matrixhub'"
fi

step "Done"
info "Next steps:"
info "  bash scripts/diagnosis.sh                                # run a full health report"
info "  curl -fsS https://api.matrixhub.io/health?check_db=true  # public smoke test"
info "  bash scripts/update.sh                                   # later, when a new release is published"
