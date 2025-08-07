#!/usr/bin/env bash
#
# scripts/register_mcpgateway.sh
#
# Registers tools, resources, servers, gateways and prompts in MCP-Gateway via its API,
# using the same JWT-minting helper as verify-servers.sh.

set -euo pipefail

# — Paths & Config —
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
GATEWAY_PROJECT="${BASE_DIR}/mcpgateway"
VENV_ACTIVATE="${GATEWAY_PROJECT}/.venv/bin/activate"
ENV_FILE="${GATEWAY_PROJECT}/.env"

# pick up PORT from env or default to 4444
PORT="${PORT:-4444}"
GATEWAY_URL="${GATEWAY_URL:-http://127.0.0.1:${PORT}}"

# strip any trailing /admin
if [[ "$GATEWAY_URL" =~ /admin/?$ ]]; then
  cleaned="${GATEWAY_URL%/admin}"
  cleaned="${cleaned%/}"
  GATEWAY_URL="$cleaned"
fi

log() { echo "[$(date +'%T')] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

log "🔄 Starting MCP-Gateway catalog registration against $GATEWAY_URL …"

# 1) Activate venv
[[ -f "$VENV_ACTIVATE" ]] || die "Virtualenv not found at $VENV_ACTIVATE; run setup first."
# shellcheck disable=SC1090
source "$VENV_ACTIVATE"
log "🐍 Activated virtualenv."

# 2) Load .env
[[ -f "$ENV_FILE" ]] || die ".env not found at $ENV_FILE; run setup first."
set -o allexport
# shellcheck disable=SC1090
source "$ENV_FILE"
set +o allexport
log "⚙️  Loaded environment from $ENV_FILE."

# 3) Mint admin JWT
auth_user="${BASIC_AUTH_USERNAME:-admin}"
jwt_secret="${JWT_SECRET_KEY:-my-test-key}"
log "🔑 Minting ADMIN_TOKEN for '$auth_user'…"
ADMIN_TOKEN="$(
  python3 -m mcpgateway.utils.create_jwt_token \
    --username "$auth_user" \
    --secret   "$jwt_secret" \
    --exp      120
)"
[[ -n "$ADMIN_TOKEN" ]] || die "Failed to mint JWT; check JWT_SECRET_KEY."
log "✅ ADMIN_TOKEN ready."

# jcurl helper
jcurl() {
  curl -sS \
       -H "Authorization: Bearer $ADMIN_TOKEN" \
       -H "Content-Type: application/json" \
       "$@"
}

cd "$GATEWAY_PROJECT"

# 4) Tools
if compgen -G "tools/*.json" > /dev/null; then
  log "🛠  Registering tools…"
  for f in tools/*.json; do
    id=$(jq -r .id "$f")
    log " • $id"
    http=$(jcurl -w "%{http_code}" -o /dev/null -d @"$f" "$GATEWAY_URL/tools")
    if [[ $http == 2* ]]; then
      log "   ✅"
    elif [[ $http == 409 ]]; then
      log "   ⚠️  already exists"
    else
      die "Tool '$id' failed (HTTP $http)"
    fi
  done
else
  log "ℹ️  No tools to register."
fi

# 5) Resources
if compgen -G "resources/*.json" > /dev/null; then
  log "📦 Registering resources…"
  for f in resources/*.json; do
    nm=$(jq -r .name "$f")
    log " • $nm"
    http=$(jcurl -w "%{http_code}" -o /dev/null -d @"$f" "$GATEWAY_URL/resources")
    if [[ $http == 2* ]]; then
      log "   ✅"
    elif [[ $http == 409 ]]; then
      log "   ⚠️  already exists"
    else
      die "Resource '$nm' failed (HTTP $http)"
    fi
  done
else
  log "ℹ️  No resources to register."
fi

# 6) Servers & Gateways
if compgen -G "servers/*.json" > /dev/null; then
  log "🚀 Registering servers/gateways…"
  for f in servers/*.json; do
    nm=$(jq -r .name "$f")
    if jq -e 'has("url")' "$f" > /dev/null; then
      ep="gateways"
      note="(gateway)"
    else
      ep="servers"
      note="(server)"
    fi

    log " • $nm $note → /$ep"
    http=$(jcurl -w "%{http_code}" -o /dev/null -d @"$f" "$GATEWAY_URL/$ep")
    if [[ $http == 2* ]]; then
      log "   ✅"
    elif [[ $http == 409 ]]; then
      log "   ⚠️  already exists"
    else
      die "$(tr '[:lower:]' '[:upper:]' <<<${ep:0:1})${ep:1} '$nm' failed (HTTP $http)"
    fi
  done
else
  log "ℹ️  No servers/gateways to register."
fi

# 7) Prompts
if compgen -G "prompts/*.json" > /dev/null; then
  log "💬 Registering prompts…"
  for f in prompts/*.json; do
    id=$(jq -r .id "$f")
    log " • $id"
    http=$(jcurl -w "%{http_code}" -o /dev/null -d @"$f" "$GATEWAY_URL/prompts")
    if [[ $http == 2* ]]; then
      log "   ✅"
    elif [[ $http == 409 ]]; then
      log "   ⚠️  already exists"
    else
      die "Prompt '$id' failed (HTTP $http)"
    fi
  done
else
  log "ℹ️  No prompts to register."
fi

# 8) Final catalog dump
log "🔍 Catalog at $GATEWAY_URL:"
echo "- Tools:"     && jcurl "$GATEWAY_URL/tools"     | jq .
echo "- Resources:" && jcurl "$GATEWAY_URL/resources" | jq .
echo "- Servers:"   && jcurl "$GATEWAY_URL/servers"   | jq .
echo "- Gateways:"  && jcurl "$GATEWAY_URL/gateways"  | jq .
echo "- Prompts:"   && jcurl "$GATEWAY_URL/prompts"   | jq .

log "🎉 All done!"
