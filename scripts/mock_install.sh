#!/usr/bin/env bash
set -euo pipefail

# ————————————— Configuration (override via ENV) —————————————
HUB_URL="${HUB_URL:-http://127.0.0.1:7300}"
GATEWAY_URL="${GATEWAY_URL:-http://127.0.0.1:4444}"
DB_PATH="${DB_PATH:-./data/catalog.sqlite}"
REMOTE_INDEX="${REMOTE_INDEX:-https://raw.githubusercontent.com/ruslanmv/hello-mcp/refs/heads/main/matrix/index.json}"

# 1) Use Hub’s jwt_helper so we stay in this venv
export JWT_SECRET_KEY="${JWT_SECRET_KEY:-my-test-key}"
export BASIC_AUTH_USERNAME="${BASIC_AUTH_USERNAME:-admin}"
# Optional fallback: export ADMIN_TOKEN="eyJ…"

# ————————————— 1) Choose a manifest URL —————————————
echo "▶️ Fetching index.json from ${REMOTE_INDEX}…"
MANIFEST_URL="$(
  curl -fsSL "$REMOTE_INDEX" \
    | jq -r '
        if (.manifests? | type=="array") then .manifests[0]
        elif (.items? | type=="array")    then .items[0].manifest_url
        elif (.entries? | type=="array")  then "\(.entries[0].base_url)\(.entries[0].path)"
        else empty end
      '
)"
[[ -n "$MANIFEST_URL" ]] || { echo "✖ No manifest URL found"; exit 1; }
echo "✔ Manifest URL: $MANIFEST_URL"

# ————————————— 2) Download manifest + build payload —————————————
echo "▶️ Downloading manifest…"
MANIFEST_JSON="$(curl -fsSL "$MANIFEST_URL")"

# Compute uid = type:id@version
ENTITY_UID="$(
  echo "$MANIFEST_JSON" | jq -r '"\(.type):\(.id)@\(.version)"'
)"
echo "✔ Entity UID: $ENTITY_UID"

PAYLOAD="$(
  jq -n \
    --arg id     "$ENTITY_UID" \
    --arg target "./" \
    --argjson m  "$MANIFEST_JSON" \
    '{id: $id, target: $target, manifest: $m}'
)"
echo -e "\n▶️ Payload for /catalog/install:"
echo "$PAYLOAD" | jq .

# ————————————— 3) POST to Matrix Hub —————————————
echo -e "\n▶️ Installing into Matrix Hub…"
INSTALL_RES="$(
  curl -fsSL -X POST "${HUB_URL}/catalog/install" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD"
)"
echo "$INSTALL_RES" | jq .

# ————————————— 4) Poll /servers on MCP-Gateway —————————————
echo -e "\n▶️ Verifying Gateway registration…"
for i in {1..6}; do
  echo "  • Attempt $i: GET ${GATEWAY_URL}/servers"
  # Mint fresh JWT using Hub's helper
  ADMIN_TOKEN="$(
    python3 - <<PYCODE
import os
from src.utils.jwt_helper import get_mcp_admin_token
print(get_mcp_admin_token(
    secret=os.getenv("JWT_SECRET_KEY"),
    username=os.getenv("BASIC_AUTH_USERNAME"),
    ttl_seconds=300,
    fallback_token=os.getenv("ADMIN_TOKEN", None),
))
PYCODE
  )"
  SERVERS_JSON="$(
    curl -fsSL \
      -H "Authorization: Bearer $ADMIN_TOKEN" \
      "${GATEWAY_URL}/servers"
  )"
  echo "$SERVERS_JSON" | jq .

  if echo "$SERVERS_JSON" \
       | jq -e --arg name "$ENTITY_UID" '.[] | select(.name==$name)' \
       > /dev/null; then
    echo "✅ Server $ENTITY_UID registered!"
    break
  fi

  echo "  …not yet there, sleeping 2s"
  sleep 2
done

# ————————————— 5) Inspect Hub DB —————————————
echo -e "\n▶️ Recent entries in Hub catalog (SQLite DB ${DB_PATH}):"
sqlite3 "$DB_PATH" <<'SQL'
.headers on
.mode column
SELECT uid, type, name, version, created_at
FROM entity
ORDER BY created_at DESC
LIMIT 5;
SQL

echo -e "\n🎉 Done."
