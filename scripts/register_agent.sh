#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# scripts/register_agent.sh
#   - Registers the 'chat' tool
#   - Registers examples/agents/watsonx-agent/server.py as an inline resource
#   - Registers a federated gateway pointing at the local watsonx-agent SSE endpoint
# -----------------------------------------------------------------------------

# 1) Activate MCP-Gateway virtualenv
VENV="./mcpgateway/.venv/bin/activate"
if [[ ! -f "$VENV" ]]; then
  echo "❌ Virtualenv missing at $VENV"
  exit 1
fi
# shellcheck disable=SC1090
source "$VENV"
echo "✅ Activated mcpgateway virtualenv"

# 2) Credentials
export BASIC_AUTH_USER="${BASIC_AUTH_USER:-admin}"
export BASIC_AUTH_PASSWORD="${BASIC_AUTH_PASSWORD:-changeme}"
export JWT_SECRET_KEY="${JWT_SECRET_KEY:-my-test-key}"

# 3) Mint ADMIN_TOKEN
echo "🔑 Generating ADMIN_TOKEN…"
ADMIN_TOKEN=$(
  python -m mcpgateway.utils.create_jwt_token \
    --username "$BASIC_AUTH_USER" \
    --secret   "$JWT_SECRET_KEY"  \
    --exp      60
)
echo "✅ ADMIN_TOKEN generated"

# Helper for authenticated JSON calls
jcurl() {
  curl -s -H "Authorization: Bearer ${ADMIN_TOKEN}" \
       -H "Content-Type: application/json" "$@"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP A) Ensure 'chat' tool exists
# ─────────────────────────────────────────────────────────────────────────────
TOOL_ID="chat"
echo "🛠 Ensuring tool '$TOOL_ID' exists…"

TOOL_PAYLOAD=$(
  jq -n \
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
  echo "⚠️ Tool already exists (HTTP 409), skipping"
else
  echo "❌ Tool registration failed (HTTP $TOOL_CODE):"
  sed '$d' <<<"$TOOL_RAW"
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP B) Ensure inline resource exists
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_PATH="examples/agents/watsonx-agent/server.py"
SCRIPT_NAME="$(basename "$SCRIPT_PATH")"
RESOURCE_URI="file://$SCRIPT_PATH"

echo "📦 Reading resource file…"
CONTENT=$(<"$SCRIPT_PATH")

echo "📦 Ensuring resource '$SCRIPT_NAME' exists…"
RES_PAYLOAD=$(
  jq -n \
    --arg id   "$SCRIPT_NAME" \
    --arg name "$SCRIPT_NAME" \
    --arg uri  "$RESOURCE_URI" \
    --arg code "$CONTENT" \
    '{id:$id,name:$name,type:"inline",uri:$uri,content:$code}'
)

RES_RAW=$(jcurl -w "\n%{http_code}" -d "$RES_PAYLOAD" http://localhost:4444/resources)
RES_BODY=$(sed '$d' <<<"$RES_RAW")
RES_CODE=$(tail -n1 <<<"$RES_RAW")

echo "🔍 [DEBUG] Resource POST response body:"
echo "$RES_BODY" | jq .
echo "🔍 [DEBUG] Resource POST HTTP status: $RES_CODE"

if [[ $RES_CODE =~ ^2 ]]; then
  echo "✅ Resource registered (HTTP $RES_CODE)"
elif [[ $RES_CODE == "409" ]]; then
  echo "⚠️ Resource already exists (HTTP 409), skipping"
  RESOURCE_NUM_ID=$(
    jcurl http://localhost:4444/resources \
    | jq -r --arg uri "$RESOURCE_URI" '.[] | select(.uri==$uri) | .id'
  )
  if [[ -n "$RESOURCE_NUM_ID" ]]; then
    echo "ℹ️ Found existing RESOURCE_NUM_ID=$RESOURCE_NUM_ID"
  else
    echo "❌ Could not find existing resource ID after 409"
    exit 1
  fi
else
  echo "❌ Resource registration failed (HTTP $RES_CODE):"
  echo "$RES_BODY"
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP C) If the POST returned a new resource, extract its numeric ID
# ─────────────────────────────────────────────────────────────────────────────
if [[ -z "${RESOURCE_NUM_ID:-}" ]]; then
  RESOURCE_NUM_ID=$(jq -r '.id // empty' <<<"$RES_BODY")
  if [[ -z "$RESOURCE_NUM_ID" ]]; then
    echo "❌ Failed to parse numeric resource ID from response body"
    exit 1
  fi
  echo "ℹ️ Found RESOURCE_NUM_ID=$RESOURCE_NUM_ID"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP D) Register federated gateway tying tool + resource together
#            (requires a 'url' field pointing at SSE endpoint)
# ─────────────────────────────────────────────────────────────────────────────
GATEWAY_NAME="watsonx-chat-agent"
GATEWAY_DESC="Chat with IBM watsonx.ai via SSE"

# Default to the local SSE endpoint; override with AGENT_URL if needed
GATEWAY_URL="${AGENT_URL:-http://127.0.0.1:6288/sse}"

# If someone set AGENT_URL to include '/admin', strip it
if [[ "$GATEWAY_URL" =~ /admin/?$ ]]; then
  cleaned="${GATEWAY_URL%/admin}"
  cleaned="${cleaned%/}"
  echo "ℹ️ Stripping '/admin' from AGENT_URL; using $cleaned"
  GATEWAY_URL="$cleaned"
fi

echo "🚀 Registering gateway '$GATEWAY_NAME' at $GATEWAY_URL …"

TOOLS_JSON=$(jq -cn --arg t "$TOOL_ID"          '[ $t ]')
RES_JSON=$(jq -cn --argjson r "$RESOURCE_NUM_ID" '[ $r ]')
PROMPTS_JSON='[]'

GW_PAYLOAD=$(
  jq -n \
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
  echo "⚠️ Gateway already exists (HTTP 409), skipping"
else
  echo "❌ Gateway registration failed (HTTP $GW_CODE):"
  echo "$GW_BODY"
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# FINAL) Show current Tools & Gateways
# ─────────────────────────────────────────────────────────────────────────────
echo -e "\n🔍 Current Tools:"
jcurl http://localhost:4444/tools | jq .
echo -e "\n🔍 Current Gateways:"
jcurl http://localhost:4444/gateways | jq .
