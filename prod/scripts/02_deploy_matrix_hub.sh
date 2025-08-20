#!/usr/bin/env bash
set -euo pipefail

# ===== Config (override via env or edit here) =====
APP_NAME="${APP_NAME:-matrix-hub}"
APP_DIR="${APP_DIR:-/opt/matrix-hub}"
REPO_URL="${REPO_URL:-https://github.com/agent-matrix/matrix-hub}"  # default to official repo
SOURCE_DIR="${SOURCE_DIR:-}"        # if you want to deploy from a local directory instead
EXPOSE_API_PORT="${EXPOSE_API_PORT:-7300}"
EXPOSE_GATEWAY_PORT="${EXPOSE_GATEWAY_PORT:-4444}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:16-alpine}"
POSTGRES_USER="${POSTGRES_USER:-matrix}"
POSTGRES_DB="${POSTGRES_DB:-matrixhub}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"      # if empty, will be generated
API_TOKEN="${API_TOKEN:-}"                      # if empty, will be generated
MCP_GATEWAY_TOKEN="${MCP_GATEWAY_TOKEN:-}"      # if empty, will be generated
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.prod.yml}"  # repo ships this file

# ===== Helpers =====
need_cmd() { command -v "$1" >/dev/null 2>&1; }
random_hex() { openssl rand -hex 24; }
abort() { echo "ERROR: $*" >&2; exit 1; }

# ===== Checks =====
need_cmd docker || abort "docker not found. Run 01_setup_docker_ubuntu2004.sh first and re-login."
need_cmd openssl || abort "openssl is required."

# Ensure docker daemon is up
if ! systemctl is-active --quiet docker; then
  sudo systemctl start docker || true
fi

# Determine non-root owner
OWNER="${SUDO_USER:-$USER}"

echo "==> Preparing ${APP_DIR}"
sudo mkdir -p "${APP_DIR}"
sudo chown -R "${OWNER}":"${OWNER}" "${APP_DIR}"

# ===== Obtain source =====
if [[ -n "${REPO_URL}" && -z "${SOURCE_DIR}" ]]; then
  echo "==> Cloning ${REPO_URL}"
  if [[ ! -d "${APP_DIR}/src/.git" ]]; then
    git clone "${REPO_URL}" "${APP_DIR}/src"
  else
    (cd "${APP_DIR}/src" && git fetch --all && git pull --ff-only)
  fi
elif [[ -n "${SOURCE_DIR}" ]]; then
  echo "==> Copying from ${SOURCE_DIR}"
  rsync -a --delete --exclude ".venv" --exclude ".git" "${SOURCE_DIR}/" "${APP_DIR}/src/"
else
  echo "==> No REPO_URL or SOURCE_DIR provided. Assuming project already exists at ${APP_DIR}/src"
fi

# ===== .env =====
cd "${APP_DIR}/src"
if [[ -z "${POSTGRES_PASSWORD}" ]]; then POSTGRES_PASSWORD="$(random_hex)"; fi
if [[ -z "${API_TOKEN}" ]]; then API_TOKEN="$(random_hex)"; fi
if [[ -z "${MCP_GATEWAY_TOKEN}" ]]; then MCP_GATEWAY_TOKEN="$(random_hex)"; fi

DB_URL="postgresql+psycopg://${POSTGRES_USER}:${POSTGRES_PASSWORD}@db:5432/${POSTGRES_DB}"

ENV_PATH="${APP_DIR}/src/.env"
if [[ ! -f "${ENV_PATH}" ]]; then
  if [[ -f ".env.example" ]]; then
    echo "==> Creating .env from .env.example and injecting secrets"
    cp .env.example "${ENV_PATH}"
    # Best-effort replacements if keys exist in example; otherwise append.
    sed -i "s|^POSTGRES_USER=.*|POSTGRES_USER=${POSTGRES_USER}|g" "${ENV_PATH}" || true
    sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${POSTGRES_PASSWORD}|g" "${ENV_PATH}" || true
    sed -i "s|^POSTGRES_DB=.*|POSTGRES_DB=${POSTGRES_DB}|g" "${ENV_PATH}" || true
    sed -i "s|^DATABASE_URL=.*|DATABASE_URL=${DB_URL}|g" "${ENV_PATH}" || true
    sed -i "s|^API_TOKEN=.*|API_TOKEN=${API_TOKEN}|g" "${ENV_PATH}" || true
    sed -i "s|^MCP_GATEWAY_TOKEN=.*|MCP_GATEWAY_TOKEN=${MCP_GATEWAY_TOKEN}|g" "${ENV_PATH}" || true
    {
      grep -q "^POSTGRES_USER=" "${ENV_PATH}" || echo "POSTGRES_USER=${POSTGRES_USER}";
      grep -q "^POSTGRES_PASSWORD=" "${ENV_PATH}" || echo "POSTGRES_PASSWORD=${POSTGRES_PASSWORD}";
      grep -q "^POSTGRES_DB=" "${ENV_PATH}" || echo "POSTGRES_DB=${POSTGRES_DB}";
      grep -q "^DATABASE_URL=" "${ENV_PATH}" || echo "DATABASE_URL=${DB_URL}";
      grep -q "^API_TOKEN=" "${ENV_PATH}" || echo "API_TOKEN=${API_TOKEN}";
      grep -q "^MCP_GATEWAY_TOKEN=" "${ENV_PATH}" || echo "MCP_GATEWAY_TOKEN=${MCP_GATEWAY_TOKEN}";
    } >> "${ENV_PATH}"
  else
    echo "==> Creating minimal .env"
    cat > "${ENV_PATH}" <<EOF
POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=${POSTGRES_DB}
DATABASE_URL=${DB_URL}
API_TOKEN=${API_TOKEN}
MCP_GATEWAY_TOKEN=${MCP_GATEWAY_TOKEN}
EOF
  fi
else
  echo "==> Using existing .env (no changes made)"
fi

# ===== Compose up =====
if [[ ! -f "${COMPOSE_FILE}" ]]; then
  echo "ERROR: ${COMPOSE_FILE} not found in $(pwd)."
  echo "Make sure you're deploying the correct repo/branch."
  exit 1
fi

echo "==> Building and starting containers with ${COMPOSE_FILE}"
docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_PATH}" up -d --build

# ===== Migrations (best-effort) =====
echo "==> Running database migrations (best effort)"
try_migration() {
  local svc="$1"
  if docker compose -f "${COMPOSE_FILE}" exec -T "${svc}" sh -lc 'command -v alembic >/dev/null 2>&1'; then
    docker compose -f "${COMPOSE_FILE}" exec -T "${svc}" alembic upgrade head && return 0
  fi
  return 1
}
sleep 3
try_migration hub || try_migration app || echo "Alembic not found or migration failed (non-fatal)."

# ===== Health checks (best-effort) =====
echo "==> Checking health endpoints (best effort)"
sleep 2
curl -fsS "http://127.0.0.1:${EXPOSE_API_PORT}/health" || true
curl -fsS "http://127.0.0.1:${EXPOSE_API_PORT}/health?check_db=true" || true

cat <<MSG

✅ Deployment complete.

Ports (host):
- API:     http://<your-host>:${EXPOSE_API_PORT}
- Gateway: http://<your-host>:${EXPOSE_GATEWAY_PORT}

Paths:
- Repo dir: ${APP_DIR}/src
- Env file: ${ENV_PATH}
- Compose:  ${APP_DIR}/src/${COMPOSE_FILE}

Useful commands:
  cd ${APP_DIR}/src
  docker compose -f ${COMPOSE_FILE} ps
  docker compose -f ${COMPOSE_FILE} logs -f
  docker compose -f ${COMPOSE_FILE} exec hub bash || docker compose -f ${COMPOSE_FILE} exec app bash
  docker compose -f ${COMPOSE_FILE} exec db psql -U ${POSTGRES_USER} -d ${POSTGRES_DB}

Backups:
  docker exec -t \$(docker compose -f ${COMPOSE_FILE} ps -q db) pg_dump -U ${POSTGRES_USER} ${POSTGRES_DB} > backup_\$(date +%F).sql

MSG
