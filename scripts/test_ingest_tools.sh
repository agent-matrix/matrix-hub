#!/usr/bin/env bash
set -euo pipefail

# ——————————————————————————————————
# Load .env first (auto-export all vars)
# ——————————————————————————————————
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"
ENV_FILE="${ENV_FILE:-${PROJECT_ROOT}/.env}"

if [[ -f "$ENV_FILE" ]]; then
  echo "ℹ️  Loading env from: $ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
else
  echo "ℹ️  No env file at $ENV_FILE (set ENV_FILE=... to override)."
fi

# ——————————————————————————————————
# Small helpers
# ——————————————————————————————————
have() { command -v "$1" >/dev/null 2>&1; }

# Try to pick the first URL from a JSON array string (e.g. ["https://..", ...])
first_remote_from_json_array() {
  local raw="${1:-}"
  [[ -z "$raw" ]] && { echo ""; return; }
  if have jq; then
    # Works when raw is '["...","..."]' or already a parsed-looking string.
    # If it's a bare URL string, this will fail and we return empty.
    echo "$raw" | jq -r 'try (if type=="string" then fromjson else . end | .[0]) catch empty' 2>/dev/null || true
  else
    echo ""
  fi
}

# ——————————————————————————————————
# Config (env → defaults)
# ——————————————————————————————————
# Map HUB_BASE from .env to HUB_URL (if HUB_URL not set explicitly)
HUB_URL="${HUB_URL:-${HUB_BASE:-http://127.0.0.1:443}}"

# Prefer API_TOKEN from .env for admin-protected endpoints
ADMIN_TOKEN="${ADMIN_TOKEN:-${API_TOKEN:-}}"

# If REMOTE_INDEX not provided, try MATRIX_REMOTES then CATALOG_REMOTES
REMOTE_INDEX="${REMOTE_INDEX:-}"
if [[ -z "$REMOTE_INDEX" ]]; then
  REMOTE_INDEX="$(first_remote_from_json_array "${MATRIX_REMOTES:-}")"
fi
if [[ -z "$REMOTE_INDEX" ]]; then
  REMOTE_INDEX="$(first_remote_from_json_array "${CATALOG_REMOTES:-}")"
fi
# Final fallback
REMOTE_INDEX="${REMOTE_INDEX:-https://raw.githubusercontent.com/ruslanmv/hello-mcp/refs/heads/main/matrix/index.json}"

# DB path for local peek (only used if SQLite)
DB_PATH="${DB_PATH:-./data/catalog.sqlite}"
if [[ -n "${DATABASE_URL:-}" && "${DATABASE_URL}" == sqlite* ]]; then
  # crude extraction of the file path part after sqlite+pysqlite:///
  db_suffix="${DATABASE_URL#sqlite+pysqlite:///}"
  [[ -n "$db_suffix" ]] && DB_PATH="$db_suffix"
fi

# Optional admin token header
AUTH_HEADERS=()
[[ -n "$ADMIN_TOKEN" ]] && AUTH_HEADERS=(-H "Authorization: Bearer ${ADMIN_TOKEN}")

# Requirements
have curl || { echo "curl required" >&2; exit 1; }
have jq   || { echo "jq required" >&2; exit 1; }

echo "▶️ Health check ${HUB_URL}/health"
curl -fsS "${HUB_URL%/}/health" | jq . || true
echo

# ——————————————————————————————————
# 1) Resolve a manifest URL from index.json
# ——————————————————————————————————
echo "▶️ Fetching index.json from ${REMOTE_INDEX} …"
MANIFEST_URL="$(
  curl -fsSL "${REMOTE_INDEX}" \
  | jq -r '
      if (.manifests? | type=="array" and length>0) then
        .manifests[0]
      elif (.items? | type=="array" and length>0) then
        .items[0].manifest_url
      elif (.entries? | type=="array" and length>0) then
        ( (.entries[0].base_url // "") + (.entries[0].path // "") )
      else
        empty
      end
    '
)"
[[ -n "$MANIFEST_URL" ]] || { echo "✖ Could not extract manifest URL" >&2; exit 1; }
echo "✔ Found manifest URL: $MANIFEST_URL"

# ——————————————————————————————————
# 2) POST inline manifest to /catalog/install
#    (saves MCP server AND derives a tool, if enabled)
# ——————————————————————————————————
ENTITY_UID="${ENTITY_UID:-mcp_server:hello-sse-server@0.1.0}"

echo
echo "▶️ Installing via POST ${HUB_URL}/catalog/install (inline manifest)…"
MANIFEST_JSON="$(curl -fsSL "$MANIFEST_URL")"
PAYLOAD="$(jq -n \
  --arg id "$ENTITY_UID" \
  --arg target "./" \
  --argjson manifest "$MANIFEST_JSON" \
  '{id:$id, target:$target, manifest:$manifest}')"

curl -fsSL -X POST "${HUB_URL%/}/catalog/install" \
  "${AUTH_HEADERS[@]}" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  | jq .

# ——————————————————————————————————
# 3) Verify via API search (type=tool)
# ——————————————————————————————————
echo
echo "▶️ Searching for derived tools via API…"
SEARCH_URL="${HUB_URL%/}/catalog/search?q=hello&type=tool&include_pending=true&mode=keyword&limit=5"
echo "GET $SEARCH_URL"
RESP="$(curl -fsSL "$SEARCH_URL")" || { echo "✖ search request failed" >&2; exit 1; }
echo "$RESP" | jq .

COUNT="$(echo "$RESP" | jq -r '.items | length')"
if [[ "$COUNT" -gt 0 ]]; then
  echo "✔ API shows $COUNT tool result(s). First:"
  echo "$RESP" | jq -r '.items[0] | "  → \(.id)  (\(.name // "unnamed"))"'
else
  echo "✖ No tool results returned by API search."
  echo "  Hints:"
  echo "   • Ensure the server was started with DERIVE_TOOLS_FROM_MCP=true"
  echo "   • Try a looser query: q=hello or q=world"
  echo "   • Check DB verification below"
fi

# ——————————————————————————————————
# 4) Verify directly in SQLite (optional)
# ——————————————————————————————————
if [[ -f "$DB_PATH" && $(have sqlite3 && echo 1 || echo 0) -eq 1 ]]; then
  echo
  echo "▶️ Verifying SQLite DB at ${DB_PATH} …"
  echo "— Latest 5 entities —"
  sqlite3 -cmd ".mode column" -cmd ".headers on" "$DB_PATH" \
    "SELECT uid,type,name,version,created_at FROM entity ORDER BY created_at DESC LIMIT 5;"

  echo
  echo "— Derived tools (latest 5) —"
  sqlite3 -cmd ".mode column" -cmd ".headers on" "$DB_PATH" \
    "SELECT uid,type,name,version,created_at FROM entity WHERE type='tool' ORDER BY created_at DESC LIMIT 5;"
else
  echo
  echo "ℹ️ Skipping DB peek (sqlite3 not found or DB file missing: $DB_PATH)"
fi

echo
echo "✅ Done. Expect:"
echo "  • /catalog/install to succeed"
echo "  • /catalog/search?type=tool to return at least one item"
echo "  • A 'tool' row visible in the DB (if inspected)"
