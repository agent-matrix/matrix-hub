#!/usr/bin/env bash
# scripts/list_ingested.sh
# List all ingested mcp_server entities in Matrix Hub and show whether each is
# registered in MCP-Gateway (based on gateway_registered_at being NULL or not).
#
# Usage:
#   scripts/list_ingested.sh
#
# Env (optional):
#   DB_PATH=./data/catalog.sqlite
#   HUB_URL=http://127.0.0.1:443
#   API_TOKEN=...        # only used for API fallback
#
# Requires: sqlite3, jq (API fallback uses jq)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DB_PATH="${DB_PATH:-${ROOT_DIR}/data/catalog.sqlite}"
HUB_URL="${HUB_URL:-http://127.0.0.1:443}"
API_TOKEN="${API_TOKEN:-}"

log()  { printf "\033[1;34m➤\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m!\033[0m %s\n" "$*"; }
die()  { printf "\033[1;31m✖\033[0m %s\n" "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

if [[ -f "$DB_PATH" ]] && have sqlite3; then
  log "Reading ingested mcp_servers from DB: $DB_PATH"
  # Pretty, tabular output with computed status
  sqlite3 -header -cmd ".mode tabs" "$DB_PATH" \
    "SELECT
       uid,
       name,
       version,
       COALESCE(DATETIME(created_at), '')   AS created_at,
       CASE WHEN gateway_registered_at IS NULL THEN 'PENDING'
            ELSE 'REGISTERED'
       END AS status,
       COALESCE(gateway_error, '')          AS gateway_error
     FROM entity
     WHERE type='mcp_server'
     ORDER BY created_at DESC;" \
  | column -t -s $'\t'
  exit 0
fi

warn "DB not available (or sqlite3 missing). Falling back to API: ${HUB_URL}/gateways/pending"

# Fallback: list only the pending ones (what still needs gateway registration)
auth_flags=()
if [[ -n "$API_TOKEN" ]]; then
  auth_flags=(-H "Authorization: Bearer ${API_TOKEN}")
fi

if ! have jq; then
  die "jq is required for API fallback"
fi

resp="$(curl -fsS "${HUB_URL%/}/gateways/pending?limit=1000&offset=0" \
  "${auth_flags[@]}" \
  -H "accept: application/json")"

echo "$resp" \
| jq -r '
  .items
  | (["UID","Name","Version","Transport","Server URL","Status","Error"] | @tsv),
    (.[] | [
      .uid,
      .name,
      .version,
      (.transport // ""),
      (.server_url // ""),
      "PENDING",
      (.gateway_error // "")
    ] | @tsv)
' | column -t -s $'\t'
