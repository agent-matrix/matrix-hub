#!/usr/bin/env bash
set -euo pipefail

HUB_URL="${HUB_URL:-http://127.0.0.1:7300}"
DB_PATH="${DB_PATH:-./data/catalog.sqlite}"
REMOTE_URL="https://raw.githubusercontent.com/ruslanmv/hello-mcp/refs/heads/main/matrix/index.json"

AUTH=()
[ -n "${ADMIN_TOKEN:-}" ] && AUTH=(-H "Authorization: Bearer ${ADMIN_TOKEN}")

echo "▶️ Sending a mock ingest request to Matrix Hub…"
curl -sS -X POST "${HUB_URL}/ingest" \
  "${AUTH[@]}" \
  -H "Content-Type: application/json" \
  -d "{\"url\":\"$REMOTE_URL\"}" | jq .
