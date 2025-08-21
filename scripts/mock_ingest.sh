#!/usr/bin/env bash
set -euo pipefail

# ————————————————
# Configuration (can override via environment)
# ————————————————
HUB_URL="${HUB_URL:-http://127.0.0.1:443}"
DB_PATH="${DB_PATH:-./data/catalog.sqlite}"
REMOTE_INDEX="${REMOTE_INDEX:-https://raw.githubusercontent.com/ruslanmv/hello-mcp/refs/heads/main/matrix/index.json}"
ENTITY_UID="mcp_server:hello-sse-server@0.1.0"

# If ADMIN_TOKEN is set, include it
AUTH_HEADERS=()
if [[ -n "${ADMIN_TOKEN:-}" ]]; then
  AUTH_HEADERS=(-H "Authorization: Bearer ${ADMIN_TOKEN}")
fi

# ————————————————
# 1) Fetch index.json & pick a manifest URL
# ————————————————
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
  echo "✖ Could not extract manifest URL from index.json" >&2
  exit 1
fi
echo "✔ Found manifest URL: $MANIFEST_URL"

# ————————————————
# 2) Fetch the manifest and POST it inline to /catalog/install
# ————————————————
echo
echo "▶️ Fetching manifest and installing via POST ${HUB_URL}/catalog/install …"
# load the manifest into a variable
MANIFEST_JSON="$(curl -fsSL "$MANIFEST_URL")"

# build payload with jq to avoid quoting issues
PAYLOAD="$(jq -n \
  --arg id       "$ENTITY_UID" \
  --arg target   "./" \
  --argjson manifest "$MANIFEST_JSON" \
  '{id: $id, target: $target, manifest: $manifest}')"

echo "▶️ Payload to send:"
echo "$PAYLOAD" | jq .

# actually send it
curl -fsSL -X POST "${HUB_URL}/catalog/install" \
  "${AUTH_HEADERS[@]}" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
| jq .

# ————————————————
# 3) Verify the SQLite DB directly
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
