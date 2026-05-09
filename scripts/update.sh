#!/usr/bin/env bash
#
# scripts/update.sh — interactive Matrix Hub updater.
#
# Walks you through:
#   1. picking a target git tag (e.g. v0.1.8),
#   2. tagging the current Docker image as a rollback,
#   3. checking out the tag, rebuilding the image, restarting the container,
#   4. health-checking the new container,
#   5. offering automatic rollback if the new container is unhealthy.
#
# Read-only by default until you confirm with "y" at the destructive step.
#
# Usage:
#   bash scripts/update.sh                     # interactive
#   TARGET_TAG=v0.1.8 bash scripts/update.sh   # non-interactive
#   AUTO=1 TARGET_TAG=v0.1.8 bash scripts/update.sh   # answer yes to all
#
# Env knobs (sensible defaults):
#   CONTAINER_NAME=matrixhub
#   IMAGE_NAME=matrix-hub
#   BUILD_SCRIPT=./scripts/build_container.sh
#   RUN_SCRIPT=./scripts/run_container.sh
#   HEALTH_URL=https://127.0.0.1:443/health?check_db=true
#   HEALTH_TIMEOUT=120     # seconds to wait for /health to return 200
#   REMOTE=origin

set -Eeuo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-matrixhub}"
IMAGE_NAME="${IMAGE_NAME:-matrix-hub}"
BUILD_SCRIPT="${BUILD_SCRIPT:-./scripts/build_container.sh}"
RUN_SCRIPT="${RUN_SCRIPT:-./scripts/run_container.sh}"
HEALTH_URL="${HEALTH_URL:-https://127.0.0.1:443/health?check_db=true}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-120}"
REMOTE="${REMOTE:-origin}"
AUTO="${AUTO:-0}"

# ---------- pretty ----------
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
ok()    { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn()  { printf '  \033[33m!\033[0m %s\n' "$*"; }
bad()   { printf '  \033[31m✗\033[0m %s\n' "$*"; }
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
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

trap 'bad "update.sh aborted on line $LINENO"' ERR

# ---------- preflight ----------
step "0. Preflight"
[ -d .git ]  || { bad "run this from the matrix-hub repo root"; exit 1; }
command -v docker >/dev/null || { bad "docker not installed"; exit 1; }
command -v git    >/dev/null || { bad "git not installed";    exit 1; }
command -v curl   >/dev/null || { bad "curl not installed";   exit 1; }
[ -x "$BUILD_SCRIPT" ] || { bad "build script not found/executable: $BUILD_SCRIPT"; exit 1; }
[ -x "$RUN_SCRIPT"   ] || { bad "run   script not found/executable: $RUN_SCRIPT";   exit 1; }
ok "tooling OK"

# ---------- current state ----------
step "1. Current state"
CURRENT_BRANCH="$(git symbolic-ref --quiet --short HEAD || echo "(detached)")"
CURRENT_SHA="$(git rev-parse --short HEAD)"
CURRENT_TAG="$(git describe --tags --exact-match 2>/dev/null || echo "(no exact tag)")"
info "branch:      $CURRENT_BRANCH"
info "commit:      $CURRENT_SHA"
info "current tag: $CURRENT_TAG"

if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  CONTAINER_RUNNING=1
  CURRENT_IMAGE_ID="$(docker inspect --format='{{.Image}}' "$CONTAINER_NAME")"
  info "container:   running ($CURRENT_IMAGE_ID)"
else
  CONTAINER_RUNNING=0
  CURRENT_IMAGE_ID=""
  warn "container '$CONTAINER_NAME' is NOT running — will start fresh after build"
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
  warn "working tree has uncommitted changes:"
  git status --short | sed 's/^/      /'
  confirm "Continue anyway? Local edits could be lost." "n" || { info "aborted."; exit 0; }
fi

# ---------- fetch tags ----------
step "2. Fetching latest tags from $REMOTE"
git fetch --tags --prune "$REMOTE"
LATEST_TAG="$(git tag --list 'v*' --sort=-v:refname | head -n1)"
[ -n "$LATEST_TAG" ] || { bad "no v* tags found"; exit 1; }
ok "latest tag available: $LATEST_TAG"

# ---------- choose target ----------
step "3. Choose target tag"
if [ -n "${TARGET_TAG:-}" ]; then
  ok "TARGET_TAG=$TARGET_TAG (from env)"
else
  printf '    Recent tags:\n'
  git tag --list 'v*' --sort=-v:refname | head -n 10 | sed 's/^/      /'
  if [ "$AUTO" = "1" ]; then
    TARGET_TAG="$LATEST_TAG"
    ok "AUTO=1 → using latest: $TARGET_TAG"
  else
    read -r -p "  Target tag (default: $LATEST_TAG): " TARGET_TAG
    TARGET_TAG="${TARGET_TAG:-$LATEST_TAG}"
  fi
fi

if ! git rev-parse "refs/tags/$TARGET_TAG" >/dev/null 2>&1; then
  bad "tag $TARGET_TAG does not exist locally — typo? available:"
  git tag --list 'v*' --sort=-v:refname | head -n 10 | sed 's/^/      /'
  exit 1
fi

if [ "$CURRENT_TAG" = "$TARGET_TAG" ]; then
  warn "already on $TARGET_TAG"
  confirm "Rebuild & restart anyway?" "n" || { info "nothing to do."; exit 0; }
fi

confirm "About to checkout $TARGET_TAG, rebuild image '$IMAGE_NAME', and restart '$CONTAINER_NAME'. Proceed?" "n" \
  || { info "aborted."; exit 0; }

# ---------- pre-flight env reminder ----------
if [ -f .env ]; then
  if ! grep -qE '^DATABASE_URL=postgres' .env; then
    warn ".env does not contain a postgres DATABASE_URL — Hub will fall back to SQLite."
    confirm "Continue anyway?" "n" || { info "aborted."; exit 0; }
  fi
else
  bad ".env not found at $(pwd)/.env"
  confirm "Continue anyway?" "n" || { info "aborted."; exit 0; }
fi

# ---------- backup tag for rollback ----------
step "4. Tagging current image as rollback"
ROLLBACK_TAG=""
if [ "$CONTAINER_RUNNING" = "1" ] && [ -n "$CURRENT_IMAGE_ID" ]; then
  ROLLBACK_TAG="${IMAGE_NAME}:rollback-$(date +%Y%m%d-%H%M%S)"
  docker tag "$CURRENT_IMAGE_ID" "$ROLLBACK_TAG"
  ok "saved rollback image: $ROLLBACK_TAG"
else
  info "no running container — skipping rollback tag"
fi

# ---------- stop ----------
step "5. Stopping current container"
if [ "$CONTAINER_RUNNING" = "1" ]; then
  docker stop "$CONTAINER_NAME" >/dev/null
  docker rm   "$CONTAINER_NAME" >/dev/null
  ok "stopped & removed $CONTAINER_NAME"
else
  info "(no container running — skip)"
fi

# ---------- checkout ----------
step "6. Checking out $TARGET_TAG"
git checkout --quiet "tags/$TARGET_TAG"
ok "HEAD now at $(git rev-parse --short HEAD) ($TARGET_TAG)"

# ---------- build ----------
step "7. Building new image via $BUILD_SCRIPT"
"$BUILD_SCRIPT"
ok "build complete"

# ---------- run ----------
step "8. Starting new container via $RUN_SCRIPT"
"$RUN_SCRIPT"
sleep 2

# ---------- health ----------
step "9. Health check ($HEALTH_URL, up to ${HEALTH_TIMEOUT}s)"
deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
healthy=0
last_status=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  status="$(curl -ksS -o /tmp/_update_health.json -w '%{http_code}' --max-time 5 "$HEALTH_URL" || echo 000)"
  body="$(head -c 200 /tmp/_update_health.json 2>/dev/null || true)"
  last_status="$status"
  if [ "$status" = "200" ] && echo "$body" | grep -q '"db"[[:space:]]*:[[:space:]]*"ok"'; then
    healthy=1
    ok "/health 200 with db=ok"
    info "body: $body"
    break
  fi
  printf '    waiting… HTTP %s, body=%s\n' "$status" "${body:0:80}"
  sleep 5
done

if [ "$healthy" = "1" ]; then
  step "10. Done"
  ok "matrix-hub upgraded to $TARGET_TAG"
  if [ -n "$ROLLBACK_TAG" ]; then
    info "Rollback image kept as: $ROLLBACK_TAG"
    info "  to roll back manually: docker stop $CONTAINER_NAME && docker rm $CONTAINER_NAME"
    info "                         docker tag $ROLLBACK_TAG ${IMAGE_NAME}:latest && bash $RUN_SCRIPT"
  fi
  exit 0
fi

# ---------- failure path: offer rollback ----------
step "10. Health check FAILED (last HTTP=$last_status)"
warn "new container did not become healthy in ${HEALTH_TIMEOUT}s"
docker logs --tail=80 "$CONTAINER_NAME" 2>&1 | sed 's/^/      /' || true

if [ -z "$ROLLBACK_TAG" ]; then
  bad "no rollback image available — fix manually."
  exit 1
fi

if confirm "Roll back to previous image ($ROLLBACK_TAG)?" "y"; then
  step "11. Rolling back"
  docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
  docker rm   "$CONTAINER_NAME" >/dev/null 2>&1 || true
  docker tag  "$ROLLBACK_TAG" "${IMAGE_NAME}:latest"
  if [ "$CURRENT_TAG" != "(no exact tag)" ]; then
    git checkout --quiet "tags/$CURRENT_TAG"
    ok "git checked out back to $CURRENT_TAG"
  else
    git checkout --quiet "$CURRENT_SHA"
    ok "git checked out back to $CURRENT_SHA"
  fi
  "$RUN_SCRIPT"
  sleep 5
  rollback_status="$(curl -ksS -o /dev/null -w '%{http_code}' --max-time 5 "$HEALTH_URL" || echo 000)"
  if [ "$rollback_status" = "200" ]; then
    ok "rollback successful, /health 200"
  else
    bad "rollback container also unhealthy (HTTP $rollback_status). Investigate manually."
  fi
  exit 1
else
  warn "Leaving the broken $TARGET_TAG container running. Investigate with:"
  info "  docker logs -f $CONTAINER_NAME"
  exit 1
fi
