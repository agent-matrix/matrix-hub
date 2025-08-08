#!/usr/bin/env bash
set -euo pipefail

# Config
HUB_URL=${HUB_URL:-http://127.0.0.1:7300}
API_TOKEN=${API_TOKEN:?Set API_TOKEN = your Hub admin token}
ID=${ID:-watsonx-agent}
VER=${VER:-0.1.0}
NAME=${NAME:-"Watsonx Chat Agent"}
DESC=${DESC:-"Local Watsonx MCP server"}
# Pick ONE URL style; if your server uses /sse and you didn’t change Hub’s normalization,
# consider Option C patch below.
SERVER_URL=${SERVER_URL:-http://127.0.0.1:6288/sse}

UID="mcp_server:${ID}@${VER}"

# Inline manifest with mcp_registration
jq -n \
  --arg id    "$ID" \
  --arg name  "$NAME" \
  --arg ver   "$VER" \
  --arg desc  "$DESC" \
  --arg url   "$SERVER_URL" \
'{
  schema_version: 1,
  type: "mcp_server",
  id: $id,
  name: $name,
  version: $ver,
  summary: $desc,
  description: $desc,
  mcp_registration: {
    tool: {
      id: "watsonx.chat",
      name: "watsonx.chat",
      description: "Chat with IBM watsonx.ai",
      integration_type: "REST"
    },
    resources: [],
    prompts: [],
    server: {
      name: $id,
      description: $desc,
      transport: "SSE",
      url: $url
    }
  }
}' > /tmp/wx_manifest.json

# 1) Install inline into Matrix Hub (persists entity + mcp_registration)
curl -fsS -X POST "$HUB_URL/catalog/install" \
  -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json" \
  -d @- <<JSON
{"id":"$UID","target":"./","manifest": $(cat /tmp/wx_manifest.json)}
JSON

# 2) Trigger sync so Hub registers it into MCP‑Gateway
curl -fsS -X POST "$HUB_URL/remotes/sync" \
  -H "Authorization: Bearer $API_TOKEN" \
  -H "accept: application/json"