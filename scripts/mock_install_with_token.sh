#!/usr/bin/env bash
#
# scripts/mock_install_with_token.sh
#
# Mints a temporary admin JWT (valid 2 minutes) via PyJWT,
# then runs the mock ingest against Matrix Hub.
#

set -euo pipefail

# ————————————————
# Configuration (override via env)
# ————————————————
HUB_URL="${HUB_URL:-http://127.0.0.1:443}"
DB_PATH="${DB_PATH:-./data/catalog.sqlite}"
REMOTE_INDEX="${REMOTE_INDEX:-https://raw.githubusercontent.com/ruslanmv/hello-mcp/refs/heads/main/matrix/index.json}"
ENTITY_UID="${ENTITY_UID:-mcp_server:hello-sse-server@0.1.0}"
VENV_DIR=".venv"

# ————————————————
# 0) Activate venv (if it exists)
# ————————————————
if [[ -f "${VENV_DIR}/bin/activate" ]]; then
  # shellcheck disable=SC1090
  source "${VENV_DIR}/bin/activate"
  echo "🐍 Activated virtualenv at ${VENV_DIR}"
fi

# ————————————————
# 1) Ensure PyJWT is installed
# ————————————————
if ! python3 - << 'EOF' &>/dev/null
import jwt
EOF
then
  echo "⚙️ Installing PyJWT in venv..."
  pip install PyJWT
fi

# ————————————————
# 2) Mint ADMIN_TOKEN if not already set
# ————————————————
if [[ -z "${ADMIN_TOKEN:-}" ]]; then
  echo "⏳ Minting temporary ADMIN_TOKEN (120 s)…"
  ADMIN_TOKEN="$(
    python3 - << 'EOF'
import os, time, jwt

secret = os.getenv("JWT_SECRET_KEY", "my-test-key")
user   = os.getenv("BASIC_AUTH_USERNAME", "admin")
now    = int(time.time())

payload = {
    "sub": user,
    "iat": now,
    "exp": now + 120
}
# HS256 is assumed—adjust if your Hub uses another algorithm
token = jwt.encode(payload, secret, algorithm="HS256")
print(token)
EOF
  )"

  if [[ -z "$ADMIN_TOKEN" ]]; then
    echo "❌ Failed to mint ADMIN_TOKEN" >&2
    exit 1
  fi
  echo "✅ ADMIN_TOKEN minted."
else
  echo "🔑 Using provided ADMIN_TOKEN."
fi

AUTH_HEADERS=(-H "Authorization: Bearer ${ADMIN_TOKEN}")

# ————————————————
# 3) Fetch index.json & pick manifest URL
# ————————————————
echo
echo "▶️ Fetching index.json from ${REMOTE_INDEX} …"
MANIFEST_URL="$(
  curl -fsSL "${REMOTE_INDEX}" \
    | jq -r '
        if (.manifests? | type=="array" and length>0) then
          .manifests[0]
        elif (.items? | type=="array" and length>0) then
          .items[0].manifest_url
        elif (.entries? | type=="array" and length>0) then
          "\(.entries[0].base_url)\(.entries[0].path)"
        else
          empty
        end
      '
)"

if [[ -z "$MANIFEST_URL" ]]; then
  echo "✖ Could not extract manifest URL" >&2
  exit 1
fi
echo "✔ Found manifest URL: $MANIFEST_URL"

# ————————————————
# 4) Fetch manifest & POST to /catalog/install
# ————————————————
echo
echo "▶️ Fetching manifest and installing via POST ${HUB_URL}/catalog/install …"
MANIFEST_JSON="$(curl -fsSL "$MANIFEST_URL")"

PAYLOAD="$(jq -n \
  --arg id       "$ENTITY_UID" \
  --arg target   "./" \
  --argjson manifest "$MANIFEST_JSON" \
  '{id: $id, target: $target, manifest: $manifest}')"

echo "▶️ Payload to send:"
echo "$PAYLOAD" | jq .

curl -fsSL -X POST "${HUB_URL}/catalog/install" \
  "${AUTH_HEADERS[@]}" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
| jq .

# ————————————————
# 5) Verify SQLite DB
# ————————————————
echo
echo "▶️ Verifying SQLite DB at ${DB_PATH} …"
if [[ ! -f "${DB_PATH}" ]]; then
  echo "✖ DB file not found: ${DB_PATH}" >&2
  exit 1
fi

echo "— Listing rows in 'entity' table (latest 5) —"
sqlite3 "${DB_PATH}" <<'SQL'
.headers on
.mode column
SELECT
  uid,
  type,
  name,
  version,
  created_at
FROM entity
ORDER BY created_at DESC
LIMIT 5;
SQL

echo
echo "✅ Done. If you see your new entity above, installation succeeded."
