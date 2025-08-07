#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# scripts/register_agent_catalog.sh
#   - Registers the 'chat' tool
#   - Registers examples/agents/watsonx-agent/server.py as an inline resource
#   - Registers a federated gateway tying them together (requires 'url')
# -----------------------------------------------------------------------------

# 1) Activate the MCP-Gateway virtualenv
VENV="./mcpgateway/.venv/bin/activate"
[[ -f "$VENV" ]] || { echo "❌ Virtualenv missing at $VENV"; exit 1; }
# shellcheck disable=SC1090
source "$VENV"
echo "✅ Activated mcpgateway virtualenv"

# 2) Credentials (override via ENV if desired)
export BASIC_AUTH_USER="${BASIC_AUTH_USER:-admin}"
export BASIC_AUTH_PASSWORD="${BASIC_AUTH_PASSWORD:-changeme}"
export JWT_SECRET_KEY="${JWT_SECRET_KEY:-my-test-key}"

# 3) Mint an ADMIN_TOKEN
echo "🔑 Generating ADMIN_TOKEN…"
ADMIN_TOKEN=$(
  python -m mcpgateway.utils.create_jwt_token \
    --username "$BASIC_AUTH_USER" \
    --secret   "$JWT_SECRET_KEY" \
    --exp      60
)
echo "✅ ADMIN_TOKEN generated"

# Helper for authenticated JSON calls
jcurl() {
  curl -s -H "Authorization: Bearer ${ADMIN_TOKEN}" \
       -H "Content-Type: application/json" "$@"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP A) Register the 'chat' tool (idempotent)
# ─────────────────────────────────────────────────────────────────────────────
TOOL_ID="chat"
echo "🛠  Ensuring tool '$TOOL_ID' exists…"
TOOL_PAYLOAD=$(jq -n \
  --arg id   "$TOOL_ID" \
  --arg name "$TOOL_ID" \
  --arg desc "Watsonx chat tool" \
  --arg itype "REST" \
  '{id:$id,name:$name,description:$desc,integration_type:$itype}'
)

TOOL_RAW=$(jcurl -w "\n%{http_code}" -d "$TOOL_PAYLOAD" http://localhost:4444/tools)
TOOL_CODE=$(tail -n1 <<<"$TOOL_RAW")

if [[ $TOOL_CODE =~ ^2 ]]; then
  echo "✅ Tool registered (HTTP $TOOL_CODE)"
elif [[ $TOOL_CODE == "409" ]]; then
  echo "⚠️  Tool already exists (HTTP 409), skipping"
else
  echo "❌ Tool registration failed (HTTP $TOOL_CODE):"
  echo "$(sed '$d' <<<"$TOOL_RAW")"
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP B) Register the inline resource
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_PATH="examples/agents/watsonx-agent/server.py"
SCRIPT_NAME="$(basename "$SCRIPT_PATH")"
RESOURCE_URI="file://$SCRIPT_PATH"

echo "📦 Reading $SCRIPT_PATH…"
CONTENT=$(<"$SCRIPT_PATH")

echo "📦 Ensuring resource '$SCRIPT_NAME' is registered…"
RES_PAYLOAD=$(jq -n \
  --arg id      "$SCRIPT_NAME" \
  --arg name    "$SCRIPT_NAME" \
  --arg uri     "$RESOURCE_URI" \
  --arg code    "$CONTENT" \
  '{id:$id,name:$name,type:"inline",uri:$uri,content:$code}'
)

RES_RAW=$(jcurl -w "\n%{http_code}" -d "$RES_PAYLOAD" http://localhost:4444/resources)
RES_CODE=$(tail -n1 <<<"$RES_RAW")
RES_BODY=$(sed '$d' <<<"$RES_RAW")

if [[ $RES_CODE =~ ^2 ]]; then
  echo "✅ Resource registered (HTTP $RES_CODE)"
elif [[ $RES_CODE == "409" ]]; then
  echo "⚠️  Resource already exists (HTTP 409), skipping"
else
  echo "❌ Resource registration failed (HTTP $RES_CODE):"
  echo "$RES_BODY"
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP C) Fetch numeric ID of that resource
# ─────────────────────────────────────────────────────────────────────────────
echo "🔍 Fetching numeric ID for resource '$SCRIPT_NAME'…"
ALL_RES=$(jcurl http://localhost:4444/resources)
RESOURCE_NUM_ID=$(jq -r --arg uri "$RESOURCE_URI" '
  .[] | select(.uri == $uri) | .id
' <<<"$ALL_RES")

if [[ -z "$RESOURCE_NUM_ID" ]]; then
  echo "❌ Unable to find numeric ID for resource '$SCRIPT_NAME'"
  exit 1
fi
echo "ℹ️  Found RESOURCE_ID=$RESOURCE_NUM_ID"

# ─────────────────────────────────────────────────────────────────────────────
# STEP D) Register federated gateway tying chat + resource together
#            (requires 'url' field pointing at the agent's SSE endpoint)
# ─────────────────────────────────────────────────────────────────────────────
GATEWAY_NAME="watsonx-chat-agent"
GATEWAY_DESC="Chat with IBM watsonx.ai via SSE"

# Default to the local SSE endpoint; override with AGENT_URL if needed
GATEWAY_URL="${AGENT_URL:-http://127.0.0.1:6288/sse}"

# Strip any trailing '/admin' if present
if [[ "$GATEWAY_URL" =~ /admin/?$ ]]; then
  cleaned="${GATEWAY_URL%/admin}"
  cleaned="${cleaned%/}"
  echo "ℹ️ Stripping '/admin' from AGENT_URL; using $cleaned"
  GATEWAY_URL="$cleaned"
fi

echo "🚀 Registering gateway '$GATEWAY_NAME' at $GATEWAY_URL …"

# Build JSON arrays correctly: tools as strings, resources as numbers
TOOLS_JSON=$(jq -n --arg t "$TOOL_ID" '[ $t ]')
RES_JSON=$(jq -n --argjson r "$RESOURCE_NUM_ID" '[ $r ]')
PROMPTS_JSON='[]'

GW_PAYLOAD=$(jq -n \
  --arg name        "$GATEWAY_NAME" \
  --arg desc        "$GATEWAY_DESC" \
  --arg url         "$GATEWAY_URL" \
  --argjson tools     "$TOOLS_JSON" \
  --argjson resources "$RES_JSON" \
  --argjson prompts   "$PROMPTS_JSON" \
  '{
     name:                $name,
     description:         $desc,
     url:                 $url,
     associated_tools:      $tools,
     associated_resources:  $resources,
     associated_prompts:    $prompts
   }'
)

GW_RAW=$(jcurl -w "\n%{http_code}" -d "$GW_PAYLOAD" http://localhost:4444/gateways)
GW_BODY=$(sed '$d' <<<"$GW_RAW")
GW_CODE=$(tail -n1 <<<"$GW_RAW")

echo "🔍 [DEBUG] Gateway POST response body:"
echo "$GW_BODY" | jq .
echo "🔍 [DEBUG] Gateway POST HTTP status: $GW_CODE"

if [[ $GW_CODE =~ ^2 ]]; then
  echo "✅ Gateway registered (HTTP $GW_CODE)"
elif [[ $GW_CODE == "409" ]]; then
  echo "⚠️  Gateway already exists (HTTP 409), skipping"
else
  echo "❌ Gateway registration failed (HTTP $GW_CODE):"
  echo "$GW_BODY"
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# DONE: List current Tools & Gateways
# ─────────────────────────────────────────────────────────────────────────────
echo -e "\n🔍 Current Tools:"
jcurl http://localhost:4444/tools | jq .

echo -e "\n🔍 Current Gateways:"
jcurl http://localhost:4444/gateways | jq .
