#!/usr/bin/env bash
# scripts/verify_token.sh
# Quick sanity check that Matrix Hub can mint/obtain a token
# and that the MCP-Gateway accepts it. Also lists /servers and /gateways.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# --- Config ---
HUB_ENV_FILE="${HUB_ENV_FILE:-${ROOT_DIR}/.env}"
GATEWAY_ENV_LOCAL="${GATEWAY_ENV_LOCAL:-${ROOT_DIR}/.env.gateway.local}"
GATEWAY_URL_DEFAULT="http://127.0.0.1:4444"

log()  { printf "\033[1;34m➤\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m!\033[0m %s\n" "$*"; }
die()  { printf "\033[1;31m✖\033[0m %s\n" "$*" >&2; exit 1; }

# --- Load env (Hub) ---
if [[ -f "$HUB_ENV_FILE" ]]; then
  log "Loading Hub env: $HUB_ENV_FILE"
  # shellcheck disable=SC1090
  set -a; . "$HUB_ENV_FILE"; set +a
else
  warn "Hub env not found at $HUB_ENV_FILE (continuing)."
fi

# --- Optionally bridge from gateway local env ---
if [[ -f "$GATEWAY_ENV_LOCAL" ]]; then
  log "Loading gateway env: $GATEWAY_ENV_LOCAL"
  # shellcheck disable=SC1090
  set -a; . "$GATEWAY_ENV_LOCAL"; set +a
  # Bridge names the Hub expects
  export BASIC_AUTH_USERNAME="${BASIC_AUTH_USERNAME:-${BASIC_AUTH_USER:-admin}}"
  export MCP_GATEWAY_URL="${MCP_GATEWAY_URL:-http://127.0.0.1:${PORT:-4444}}"
fi

GATEWAY_URL="${MCP_GATEWAY_URL:-$GATEWAY_URL_DEFAULT}"
# Normalize URL: strip trailing /admin and slash
GATEWAY_URL="${GATEWAY_URL%/admin}"
GATEWAY_URL="${GATEWAY_URL%/}"

# --- Python availability check ---
PYTHON="${PYTHON:-python3}"
command -v "$PYTHON" >/dev/null 2>&1 || die "python3 not found in PATH"

# --- Print a preview of the token (first 24 chars) ---
log "Minting/obtaining token preview…"
$PYTHON - <<'PY' || die "Token preview failed"
import os
from src.utils.jwt_helper import get_mcp_admin_token
try:
    tok = get_mcp_admin_token(
        secret=os.getenv("JWT_SECRET_KEY"),
        username=(os.getenv("BASIC_AUTH_USERNAME") or os.getenv("BASIC_AUTH_USER")),
        ttl_seconds=60,
        fallback_token=os.getenv("MCP_GATEWAY_TOKEN") or os.getenv("ADMIN_TOKEN"),
    )
    print((tok or "")[:24])
except Exception as e:
    import sys
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PY

# --- Capture the full token ---
log "Acquiring full token…"
TOKEN=$($PYTHON - <<'PY'
import os
from src.utils.jwt_helper import get_mcp_admin_token
print(get_mcp_admin_token(
    secret=os.getenv("JWT_SECRET_KEY"),
    username=(os.getenv("BASIC_AUTH_USERNAME") or os.getenv("BASIC_AUTH_USER")),
    ttl_seconds=300,
    fallback_token=os.getenv("MCP_GATEWAY_TOKEN") or os.getenv("ADMIN_TOKEN"),
))
PY
)

if [[ -z "${TOKEN:-}" ]]; then
  die "Failed to obtain token"
fi

# If helper returned a Basic token, do not re-prefix; otherwise use Bearer
AUTH_HEADER="$TOKEN"
shopt -s nocasematch
if [[ ! "$AUTH_HEADER" =~ ^(Bearer|Basic)\  ]]; then
  AUTH_HEADER="Bearer $AUTH_HEADER"
fi
shopt -u nocasematch

log "Probing $GATEWAY_URL/health with Authorization: ${AUTH_HEADER%% *} …"
if ! curl -sS -H "Authorization: $AUTH_HEADER" "$GATEWAY_URL/health" | jq .; then
  die "Gateway health probe failed"
fi

# --- List catalogs ---
log "Now listing /servers (local servers) …"
SERVERS_JSON="$(curl -sS -H "Authorization: $AUTH_HEADER" "$GATEWAY_URL/servers" || true)"
if [[ -z "$SERVERS_JSON" ]]; then
  die "Gateway /servers probe failed"
fi
echo "$SERVERS_JSON" | jq . || echo "$SERVERS_JSON"

log "Now listing /gateways (federated MCP servers) …"
GATEWAYS_JSON="$(curl -sS -H "Authorization: $AUTH_HEADER" "$GATEWAY_URL/gateways" || true)"
if [[ -z "$GATEWAYS_JSON" ]]; then
  warn "Gateway /gateways probe returned empty response"
else
  echo "$GATEWAYS_JSON" | jq . || echo "$GATEWAYS_JSON"
fi

# Helpful hint if /servers is empty but /gateways has entries
if [[ "$(echo "$SERVERS_JSON"   | jq 'length' 2>/dev/null || echo 0)" -eq 0 ]] && \
   [[ "$(echo "$GATEWAYS_JSON" | jq 'length' 2>/dev/null || echo 0)" -gt 0 ]]; then
  warn "You have federated gateways registered; /servers is empty because local servers were not created. This is normal."
fi

log "✅ Token works with MCP-Gateway"
