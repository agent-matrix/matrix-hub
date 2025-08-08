#!/usr/bin/env bash
# examples/register_watsonx_local_via_gateway.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# --- Optional: load env like verify_token.sh does ---
HUB_ENV_FILE="${HUB_ENV_FILE:-${ROOT_DIR}/.env}"
GATEWAY_ENV_LOCAL="${GATEWAY_ENV_LOCAL:-${ROOT_DIR}/.env.gateway.local}"

if [[ -f "$HUB_ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a; . "$HUB_ENV_FILE"; set +a
fi
if [[ -f "$GATEWAY_ENV_LOCAL" ]]; then
  # shellcheck disable=SC1090
  set -a; . "$GATEWAY_ENV_LOCAL"; set +a
  # bridge common names
  export BASIC_AUTH_USERNAME="${BASIC_AUTH_USERNAME:-${BASIC_AUTH_USER:-admin}}"
  export MCP_GATEWAY_URL="${MCP_GATEWAY_URL:-http://127.0.0.1:${PORT:-4444}}"
fi

# --- Python available? ---
PYTHON="${PYTHON:-python3}"
command -v "$PYTHON" >/dev/null 2>&1 || { echo "python3 not found"; exit 1; }

# --- Build Authorization header (Bearer or Basic) ---
AUTH_HEADER=$($PYTHON - <<'PY'
import os
from src.utils.jwt_helper import get_mcp_admin_token

t = get_mcp_admin_token(
    secret=os.getenv('JWT_SECRET_KEY'),
    username=os.getenv('BASIC_AUTH_USERNAME') or os.getenv('BASIC_AUTH_USER'),
    ttl_seconds=300,
    fallback_token=os.getenv('MCP_GATEWAY_TOKEN') or os.getenv('ADMIN_TOKEN'),
)
t = (t or '').strip()
print(t if t.lower().startswith(('bearer ', 'basic ')) else f'Bearer {t}')
PY
)

if [[ -z "${AUTH_HEADER:-}" ]]; then
  echo "ERROR: failed to obtain token" >&2
  exit 1
fi

# --- Normalize Gateway URL ---
GW_URL="${MCP_GATEWAY_URL:-http://127.0.0.1:4444}"
GW_URL="${GW_URL%/admin}"
GW_URL="${GW_URL%/}"

# --- Config for your local server ---
NAME="${NAME:-watsonx-agent}"
DESC="${DESC:-Local Watsonx MCP}"
SERVER_URL="${SERVER_URL:-http://127.0.0.1:6288/sse}"  # swap to /messages/ if you proxy/adjust

# --- Optional: quick health probe (nice to have) ---
if ! curl -fsS -H "Authorization: $AUTH_HEADER" "$GW_URL/health" | jq . >/dev/null 2>&1; then
  echo "WARN: /health probe failed (continuing)" >&2
fi

# --- Register gateway ---
jq -n --arg name "$NAME" --arg desc "$DESC" --arg url "$SERVER_URL" \
'{
  name: $name,
  description: $desc,
  url: $url,
  associated_tools: [],
  associated_resources: [],
  associated_prompts: []
}' | curl -fsS -X POST "$GW_URL/gateways" \
  -H "Authorization: $AUTH_HEADER" \
  -H "Content-Type: application/json" \
  -d @- | jq .

# --- Verify ---
curl -fsS -H "Authorization: $AUTH_HEADER" "$GW_URL/gateways" | jq .
