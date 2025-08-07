#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Usage check
# -----------------------------------------------------------------------------
if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <server-name-or-uuid>" >&2
  exit 1
fi
TARGET="$1"

# -----------------------------------------------------------------------------
# 1) Activate the project venv
# -----------------------------------------------------------------------------
VENV="./mcpgateway/.venv/bin/activate"
if [ ! -f "$VENV" ]; then
  echo "❌ Virtualenv not found; please run setup first." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$VENV"
echo "✅ Activated virtualenv"

# -----------------------------------------------------------------------------
# 2) Load or default admin credentials
# -----------------------------------------------------------------------------
export BASIC_AUTH_USER="${BASIC_AUTH_USER:-admin}"
export BASIC_AUTH_PASSWORD="${BASIC_AUTH_PASSWORD:-changeme}"
export JWT_SECRET_KEY="${JWT_SECRET_KEY:-my-test-key}"

# -----------------------------------------------------------------------------
# 3) Generate a short-lived ADMIN_TOKEN
# -----------------------------------------------------------------------------
ADMIN_TOKEN=$(
  JWT_SECRET_KEY="$JWT_SECRET_KEY" \
    python3 -m mcpgateway.utils.create_jwt_token \
      --username "$BASIC_AUTH_USER" \
      --secret   "$JWT_SECRET_KEY" \
      --exp      60
)
echo "✅ ADMIN_TOKEN generated"

# -----------------------------------------------------------------------------
# 4) Resolve TARGET to a server ID (support 32-hex and dashed UUIDs)
# -----------------------------------------------------------------------------
echo "🔍 Resolving server ID for '$TARGET'…"
RESP=$(curl -s -H "Authorization: Bearer $ADMIN_TOKEN" \
            http://localhost:4444/servers)

if [[ "$TARGET" =~ ^([0-9a-fA-F]{32}|[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})$ ]]; then
  SERVER_ID="$TARGET"
else
  SERVER_ID=$(echo "$RESP" \
    | jq -r --arg NAME "$TARGET" \
      '( .servers? // . )[] 
       | select(.name == $NAME) 
       | .id')
fi

if [[ -z "$SERVER_ID" || "$SERVER_ID" == "null" ]]; then
  echo "❌ Server '$TARGET' not found." >&2
  exit 1
fi
echo "ℹ️  Resolved to ID: $SERVER_ID"

# -----------------------------------------------------------------------------
# 5) Confirm & DELETE
# -----------------------------------------------------------------------------
read -r -p "Are you sure you want to unregister '$TARGET' (ID: $SERVER_ID)? [y/N] " CONFIRM
if [[ "${CONFIRM,,}" != "y" ]]; then
  echo "Aborted."
  exit 0
fi

HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  -X DELETE http://localhost:4444/servers/"$SERVER_ID" \
  -H "Authorization: Bearer $ADMIN_TOKEN"
)
if [[ "$HTTP_STATUS" -ge 200 && "$HTTP_STATUS" -lt 300 ]]; then
  echo "✅ Unregistered server (ID: $SERVER_ID) — HTTP $HTTP_STATUS"
else
  echo "❌ Unregister failed with HTTP $HTTP_STATUS" >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# 6) Verify removal
# -----------------------------------------------------------------------------
echo "🔍 Remaining servers:"
curl -s \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  http://localhost:4444/servers \
| jq .