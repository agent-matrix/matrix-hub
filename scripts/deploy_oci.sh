#!/usr/bin/env bash
# scripts/deploy_oci.sh
#
# Deploy Matrix Hub to Oracle Cloud Infrastructure (OCI) instance.
# Uses SSH to pull the latest Docker image and restart the container.
#
# Prerequisites:
#   - SSH access to the OCI instance (key-based auth)
#   - Docker installed on the OCI instance
#   - .env file at /home/opc/matrix-hub/.env on the remote host
#
# Usage:
#   ./scripts/deploy_oci.sh                           # Deploy latest
#   IMAGE_TAG=v1.2.3 ./scripts/deploy_oci.sh          # Deploy specific version
#   OCI_HOST=1.2.3.4 OCI_USER=ubuntu ./scripts/deploy_oci.sh  # Custom host
#
# Environment variables:
#   OCI_HOST          - IP or hostname (default: 129.213.165.60)
#   OCI_USER          - SSH user (default: opc)
#   OCI_SSH_KEY       - Path to SSH private key (default: ~/.ssh/id_rsa)
#   IMAGE_TAG         - Docker image tag (default: latest)
#   DOCKER_IMAGE      - Docker image name (default: ruslanmv/matrix-hub)
#   CONTAINER_NAME    - Container name (default: matrix-hub)
#   REMOTE_ENV_FILE   - Path to .env on remote host (default: /home/opc/matrix-hub/.env)
#   HUB_PORT          - Hub port mapping (default: 443)
#   GATEWAY_PORT      - Gateway port mapping (default: 4444)
#   DRY_RUN           - Set to 1 to print commands without executing (default: 0)

set -Eeuo pipefail

# --- Configuration ---
OCI_HOST="${OCI_HOST:-129.213.165.60}"
OCI_USER="${OCI_USER:-opc}"
OCI_SSH_KEY="${OCI_SSH_KEY:-${HOME}/.ssh/id_rsa}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
DOCKER_IMAGE="${DOCKER_IMAGE:-ruslanmv/matrix-hub}"
CONTAINER_NAME="${CONTAINER_NAME:-matrix-hub}"
REMOTE_ENV_FILE="${REMOTE_ENV_FILE:-/home/${OCI_USER}/matrix-hub/.env}"
HUB_PORT="${HUB_PORT:-443}"
GATEWAY_PORT="${GATEWAY_PORT:-4444}"
DRY_RUN="${DRY_RUN:-0}"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { printf "${GREEN}[deploy]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[deploy]${NC} %s\n" "$*" >&2; }
err()  { printf "${RED}[deploy]${NC} %s\n" "$*" >&2; exit 1; }
info() { printf "${CYAN}[deploy]${NC} %s\n" "$*"; }

# --- Validate prerequisites ---
[ -f "${OCI_SSH_KEY}" ] || err "SSH key not found: ${OCI_SSH_KEY}"
command -v ssh >/dev/null 2>&1 || err "ssh not found. Install OpenSSH."

# --- SSH helper ---
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30 -i "${OCI_SSH_KEY}")

remote_exec() {
  if [ "${DRY_RUN}" = "1" ]; then
    info "[DRY RUN] ssh ${OCI_USER}@${OCI_HOST} $*"
    return 0
  fi
  ssh "${SSH_OPTS[@]}" "${OCI_USER}@${OCI_HOST}" "$@"
}

# --- Deploy ---
echo ""
info "======================================"
info "  Matrix Hub — OCI Deployment"
info "======================================"
echo ""
log "Host:      ${OCI_USER}@${OCI_HOST}"
log "Image:     ${DOCKER_IMAGE}:${IMAGE_TAG}"
log "Container: ${CONTAINER_NAME}"
log "Ports:     ${HUB_PORT}:443, ${GATEWAY_PORT}:4444"
echo ""

# Test SSH connectivity
log "Testing SSH connection..."
remote_exec "echo 'SSH connection OK'" || err "Cannot connect to ${OCI_HOST}"

# Pull image
log "Pulling Docker image ${DOCKER_IMAGE}:${IMAGE_TAG}..."
remote_exec "docker pull ${DOCKER_IMAGE}:${IMAGE_TAG}"

# Stop and remove old container
log "Stopping current container..."
remote_exec "docker stop ${CONTAINER_NAME} 2>/dev/null || true"
remote_exec "docker rm ${CONTAINER_NAME} 2>/dev/null || true"

# Start new container
log "Starting new container..."
remote_exec "docker run -d \
  --name ${CONTAINER_NAME} \
  --restart unless-stopped \
  -p ${HUB_PORT}:443 \
  -p ${GATEWAY_PORT}:4444 \
  --env-file ${REMOTE_ENV_FILE} \
  -v matrixhub_data:/app/data \
  ${DOCKER_IMAGE}:${IMAGE_TAG}"

# Health check
log "Waiting for health check..."
RETRIES=0
MAX_RETRIES=30
while true; do
  RESULT=$(remote_exec "curl -fsS --max-time 5 http://127.0.0.1:443/health 2>/dev/null || echo FAIL")
  if echo "${RESULT}" | grep -q '"status"'; then
    break
  fi
  RETRIES=$((RETRIES + 1))
  if [ "${RETRIES}" -ge "${MAX_RETRIES}" ]; then
    warn "Health check did not pass after ${MAX_RETRIES} attempts"
    warn "Container logs:"
    remote_exec "docker logs --tail 30 ${CONTAINER_NAME}" || true
    err "Deployment may have failed. Check container manually."
  fi
  printf "  Waiting... (%d/%d)\n" "${RETRIES}" "${MAX_RETRIES}"
  sleep 2
done

# Show health
log "Health check passed:"
remote_exec "curl -s http://127.0.0.1:443/health?check_db=true"
echo ""

# Clean up old images
log "Pruning old Docker images..."
remote_exec "docker image prune -f" >/dev/null 2>&1 || true

echo ""
info "======================================"
info "  Deployment complete!"
info "======================================"
info "  API:     https://api.matrixhub.io"
info "  Health:  https://api.matrixhub.io/health"
info "  Logs:    ssh ${OCI_USER}@${OCI_HOST} docker logs -f ${CONTAINER_NAME}"
echo ""
