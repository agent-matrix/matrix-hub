#!/usr/bin/env bash
# examples/add_watsonx-local-server.sh
set -Eeuo pipefail

: "${HUB_URL:?Set HUB_URL (e.g., http://127.0.0.1:7300)}"
: "${ADMIN_TOKEN:?Set ADMIN_TOKEN equal to the Hub's API_TOKEN}"

INDEX_URL="${INDEX_URL:-http://127.0.0.1:8000/matrix/index.json}"

echo "▶ Registering remote with Hub: ${INDEX_URL}"
curl -fsS -X POST "${HUB_URL%/}/remotes" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$(jq -nc --arg url "${INDEX_URL}" '{url:$url}') " \
  || true

echo "▶ Ingesting & syncing via /remotes/sync"
curl -fsS -X POST "${HUB_URL%/}/remotes/sync" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  || true

echo "✅ Done. Check Hub logs for gw.request/gw.response for POST /gateways"
