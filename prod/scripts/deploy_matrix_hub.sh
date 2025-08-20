#!/usr/bin/env bash
set -euo pipefail

# === Config (can override via env vars) ===
APP_DIR="${APP_DIR:-/opt/matrix-hub}"
REPO_URL="${REPO_URL:-https://github.com/agent-matrix/matrix-hub}"
SOURCE_DIR="${SOURCE_DIR:-}"
EXPOSE_API_PORT="${EXPOSE_API_PORT:-7300}"
EXPOSE_GATEWAY_PORT="${EXPOSE_GATEWAY_PORT:-4444}"
POSTGRES_USER="${POSTGRES_USER:-matrix}"
POSTGRES_DB="${POSTGRES_DB:-matrixhub}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"   # auto-gen if empty
API_TOKEN="${API_TOKEN:-}"
MCP_GATEWAY_TOKEN="${MCP_GATEWAY_TOKEN:-}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.prod.yml}"

# === Helpers ===
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing $1"; exit 1; }; }
random_hex() { openssl rand -hex 24; }

# === Checks ===
need_cmd docker
need_cmd openssl
need_cmd git
sudo systemctl start docker || true

OWNER="${SUDO_USER:-$USER}"
sudo mkdir -p "$APP_DIR"
sudo chown -R "$OWNER:$OWNER" "$APP_DIR"

# === Get source ===
if [[ -n "$SOURCE_DIR" ]]; then
  echo "==> Copying from $SOURCE_DIR"
  rsync -a --delete --exclude ".venv" --exclude ".git" "$SOURCE_DIR"/ "$APP_DIR/src/"
elif [[ ! -d "$APP_DIR/src/.git" ]]; then
  echo "==> Cloning repo from $REPO_URL"
  git clone -b master "$REPO_URL" "$APP_DIR/src"
else
  echo "==> Updating repo in $APP_DIR/src"
  (cd "$APP_DIR/src" && git checkout master && git pull --ff-only)
fi

cd "$APP_DIR/src"

# === Secrets ===
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(random_hex)}"
API_TOKEN="${API_TOKEN:-$(random_hex)}"
MCP_GATEWAY_TOKEN="${MCP_GATEWAY_TOKEN:-$(random_hex)}"
DB_URL="postgresql+psycopg://${POSTGRES_USER}:${POSTGRES_PASSWORD}@db:5432/${POSTGRES_DB}"

ENV_PATH="$APP_DIR/src/.env"
if [[ ! -f "$ENV_PATH" ]]; then
  echo "==> Creating .env"
  cat > "$ENV_PATH" <<EOF
POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=${POSTGRES_DB}
DATABASE_URL=${DB_URL}
API_TOKEN=${API_TOKEN}
MCP_GATEWAY_TOKEN=${MCP_GATEWAY_TOKEN}
EOF
else
  echo "==> Using existing .env"
fi

# === Deploy ===
[[ -f "$COMPOSE_FILE" ]] || { echo "ERROR: ${COMPOSE_FILE} not found"; exit 1; }
echo "==> Building and starting containers"
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_PATH" up -d --build

# === Run migrations (best effort) ===
echo "==> Running migrations"
sleep 3
for svc in hub app; do
  if docker compose -f "$COMPOSE_FILE" exec -T "$svc" sh -lc 'command -v alembic' >/dev/null 2>&1; then
    docker compose -f "$COMPOSE_FILE" exec -T "$svc" alembic upgrade head || true
    break
  fi
done

# === Health checks ===
echo "==> Checking health endpoints"
sleep 2
curl -fsS "http://127.0.0.1:${EXPOSE_API_PORT}/health" || true
curl -fsS "http://127.0.0.1:${EXPOSE_API_PORT}/health?check_db=true" || true

cat <<EOF

✅ Deployment complete.

Ports:
- API:     http://<host>:${EXPOSE_API_PORT}
- Gateway: http://<host>:${EXPOSE_GATEWAY_PORT}

Paths:
- Repo dir: ${APP_DIR}/src
- Env file: ${ENV_PATH}
- Compose:  ${APP_DIR}/src/${COMPOSE_FILE}

Useful commands:
  cd ${APP_DIR}/src
  docker compose -f ${COMPOSE_FILE} ps
  docker compose -f ${COMPOSE_FILE} logs -f
  docker compose -f ${COMPOSE_FILE} exec hub bash
  docker compose -f ${COMPOSE_FILE} exec db psql -U ${POSTGRES_USER} -d ${POSTGRES_DB}

Backup DB:
  docker exec -t \$(docker compose -f ${COMPOSE_FILE} ps -q db) \
    pg_dump -U ${POSTGRES_USER} ${POSTGRES_DB} > backup_\$(date +%F).sql

EOF
