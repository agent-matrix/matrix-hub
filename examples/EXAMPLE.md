# Tutorial: Register a Watsonx MCP server via Matrix Hub → mcpgateway

This quick guide shows **every practical way** to register a live MCP server (your Watsonx agent) into **mcpgateway**, using **Matrix Hub** as the orchestrator. It also includes a ready-to-run shell script.

> **Heads‑up about SSE paths**
> Matrix Hub’s install/ingest flows normalize SSE endpoints to **`/messages/`**. If your FastMCP server exposes **`/sse`** (as in the sample below), create a small alias so **`/messages/`** maps to `/sse` (e.g., via a reverse proxy) **or** adjust your server to also serve `/messages/`. The script below defaults to `/messages/` for compatibility.

---

## 0) Prerequisites

* **Watsonx agent running locally** (from your example):

  ```bash
  export WATSONX_API_KEY=...
  export WATSONX_URL=...
  export WATSONX_PROJECT_ID=...
  export MODEL_ID="ibm/granite-3-3-8b-instruct"
  export WATSONX_AGENT_PORT=6288
  python examples/agents/watsonx-agent/server.py
  ```

  The example logs show `/sse`; for Hub compatibility we’ll target `/messages/` (see note above).

* **Matrix Hub** running (e.g., at `http://127.0.0.1:7300`).

* **mcpgateway** running (e.g., at `http://127.0.0.1:4444`) with admin token/JWT configured for Hub.

---

## 1) Fast path: Inline manifest → Matrix Hub → mcpgateway

**(script you can run now)**

Create `examples/register_watsonx_local_via_hub.sh`:

```bash
#!/usr/bin/env bash
# examples/register_watsonx_local_via_hub.sh
# Push an inline manifest to Matrix Hub, then trigger /remotes/sync.
# Notes:
#  - Tool is Type MCP with an input_schema
#  - Server transport is SSE and URL defaults to /messages/
#  - Ensures a good remote exists (for ingest), prunes noisy local remote

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# --- Load env if present (HUB_URL, API_TOKEN, etc.) ---
ENV_FILE="${ENV_FILE:-${ROOT_DIR}/.env}"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a; . "$ENV_FILE"; set +a
fi

# --- Config (override via env as needed) ---
HUB_URL="${HUB_URL:-http://127.0.0.1:7300}"
API_TOKEN="${API_TOKEN:-}"     # optional; if blank, we skip auth header

# Entity identity (shows up as a federated “Gateway”)
ID="${ID:-watsonx-local}"
VER="${VER:-0.1.0}"
NAME="${NAME:-Watsonx Chat Agent}"
DESC="${DESC:-Local Watsonx MCP}"

# IMPORTANT: Matrix Hub normalizes SSE to /messages/
# If your server only exposes /sse, add a path alias so /messages/ → /sse.
SERVER_URL="${SERVER_URL:-http://127.0.0.1:6288/messages/}"

# TOOL: Type MCP with input_schema
TOOL_ID="${TOOL_ID:-code-chat}"
TOOL_NAME="${TOOL_NAME:-code-chat}"
TOOL_DESC="${TOOL_DESC:-Chat with IBM watsonx.ai (accepts str or int)}"

# Remote management (optional but recommended)
DEFAULT_REMOTE="${DEFAULT_REMOTE:-https://raw.githubusercontent.com/agent-matrix/catalog/main/index.json}"
REMOVE_NOISY_LOCAL="${REMOVE_NOISY_LOCAL:-1}"  # 1 = try to remove 127.0.0.1:8000/matrix/index.json
NOISY_LOCAL_URL="${NOISY_LOCAL_URL:-http://127.0.0.1:8000/matrix/index.json}"

# Derived (readonly)
ENTITY_UID="mcp_server:${ID}@${VER}"

# --- Auth header only if API_TOKEN is present ---
auth_flags=()
if [[ -n "$API_TOKEN" ]]; then
  auth_flags=(-H "Authorization: Bearer ${API_TOKEN}")
fi

# --- Helpers ---
log()  { printf "\033[1;34m➤\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m!\033[0m %s\n" "$*"; }
die()  { printf "\033[1;31m✖\033[0m %s\n" "$*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || die "curl not found in PATH"
command -v jq   >/dev/null 2>&1 || die "jq not found in PATH"

TMP_MANIFEST="$(mktemp -t wx_manifest.XXXXXX.json)"
trap 'rm -f "$TMP_MANIFEST"' EXIT

# --- Build inline manifest ---
jq -n \
  --arg id        "$ID" \
  --arg name      "$NAME" \
  --arg ver       "$VER" \
  --arg desc      "$DESC" \
  --arg url       "$SERVER_URL" \
  --arg tool_id   "$TOOL_ID" \
  --arg tool_name "$TOOL_NAME" \
  --arg tool_desc "$TOOL_DESC" \
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
      id: $tool_id,
      name: $tool_name,
      description: $tool_desc,
      integration_type: "MCP",
      input_schema: {
        title: "chatArguments",
        type: "object",
        properties: {
          query: { title: "Query", anyOf: [{type:"string"}, {type:"integer"}] }
        },
        required: ["query"]
      }
    },
    resources: [],
    prompts: [],
    server: {
      name: $name,
      description: $desc,
      transport: "SSE",
      url: $url,
      associated_tools:     [$tool_id],
      associated_resources: [],
      associated_prompts:   []
    }
  }
}' > "$TMP_MANIFEST"

# Build /catalog/install payload
PAYLOAD="$(jq -n \
  --arg uid "$ENTITY_UID" \
  --arg target "./" \
  --slurpfile manifest "$TMP_MANIFEST" \
  '{id:$uid, target:$target, manifest:$manifest[0]}')"

log "Installing inline manifest into Matrix Hub: ${HUB_URL}/catalog/install"
curl -fsS -X POST "${HUB_URL%/}/catalog/install" \
  "${auth_flags[@]}" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
| jq . || true

# --- Ensure remotes: add DEFAULT_REMOTE if needed; remove noisy local remote if present ---
log "Ensuring a valid remote exists (and pruning noisy local remote if present)…"
REMOTES_JSON="$(curl -fsS "${HUB_URL%/}/remotes" | jq .)"
mapfile -t CURRENT_URLS < <(echo "$REMOTES_JSON" | jq -r '.items[].url // empty')

has_default=0
has_noisy=0
for u in "${CURRENT_URLS[@]:-}"; do
  [[ "$u" == "$DEFAULT_REMOTE" ]] && has_default=1
  [[ "$u" == "$NOISY_LOCAL_URL" ]] && has_noisy=1
done

if [[ $has_default -eq 0 ]]; then
  log "Adding default remote: $DEFAULT_REMOTE"
  curl -fsS -X POST "${HUB_URL%/}/remotes" \
    "${auth_flags[@]}" \
    -H "Content-Type: application/json" \
    -d "$(jq -nc --arg url "$DEFAULT_REMOTE" '{url:$url}')" \
  | jq . || true
fi

if [[ "$REMOVE_NOISY_LOCAL" == "1" && $has_noisy -eq 1 ]]; then
  warn "Removing noisy local remote (404s in your logs): $NOISY_LOCAL_URL"
  curl -fsS -X DELETE "${HUB_URL%/}/remotes" \
    "${auth_flags[@]}" \
    -H "Content-Type: application/json" \
    -d "$(jq -nc --arg url "$NOISY_LOCAL_URL" '{url:$url}')" \
  | jq . || true
fi

# (Re)read remotes for info
REMOTES_JSON="$(curl -fsS "${HUB_URL%/}/remotes" | jq .)"
COUNT="$(echo "$REMOTES_JSON" | jq -r '.count')"
log "Remotes configured: $COUNT"
echo "$REMOTES_JSON" | jq .

# --- Trigger ingest + gateway sync ---
log "Triggering /remotes/sync (ingest + gateway registration)"
SYNC_JSON="$(curl -fsS -X POST "${HUB_URL%/}/remotes/sync" \
  "${auth_flags[@]}" \
  -H "accept: application/json")"
echo "$SYNC_JSON" | jq .

log "✅ Done."
echo "   In MCP-Gateway UI, you should now see:"
echo "   • Federated Gateways: ${NAME}  →  ${SERVER_URL}"
echo "   • Registered Tools:   ${TOOL_NAME} (Type: MCP)"
```

Run it:

```bash
chmod +x examples/register_watsonx_local_via_hub.sh
./examples/register_watsonx_local_via_hub.sh
```

---

## 2) Register via **Remote Index** (no inline manifest)

1. Publish a `matrix/index.json` that points to a manifest for your Watsonx agent.
2. In Matrix Hub UI or API:

   * `POST /remotes {"url": "https://…/matrix/index.json"}`
   * `POST /remotes/sync`
     Hub will ingest the manifest and (with our patches) register the **Gateway** automatically.

---

## 3) Directly hit **mcpgateway** (manual control)

If you want to bypass Hub and register straight to mcpgateway:

```bash
# Tool (optional for MCP, discovery will add tools too)
curl -X POST http://127.0.0.1:4444/tools \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" \
  -d '{
    "name":"code-chat",
    "description":"Chat with IBM watsonx.ai",
    "integration_type":"MCP",
    "request_type":"SSE"
  }'

# Gateway (Federated server)
curl -X POST http://127.0.0.1:4444/gateways \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" \
  -d '{
    "name":"Watsonx Chat Agent",
    "description":"Local Watsonx MCP",
    "url":"http://127.0.0.1:6288/messages/",
    "transport":"SSE"
  }'
```

---

## 4) Use the **Python wrappers** from Matrix Hub

```python
from src.services.gateway_client import register_gateway, register_tool

register_tool({
  "name": "code-chat",
  "description": "Chat with IBM watsonx.ai",
  "integration_type": "MCP",
  "request_type": "SSE"
}, idempotent=True)

register_gateway({
  "name": "Watsonx Chat Agent",
  "description": "Local Watsonx MCP",
  "url": "http://127.0.0.1:6288/messages/",
  "transport": "SSE"
}, idempotent=True)
```

---

## 5) (Optional) Create a quick **/messages/** → **/sse** alias

If your server only has `/sse`, add a lightweight path alias. Example **Caddy**:

```
:6288 {
  handle_path /messages/* {
    reverse_proxy 127.0.0.1:6288 {
      header_up Host {host}
      # /messages/* → /sse
      rewrite * /sse
    }
  }
}
```

Or with a tiny **Starlette** forwarder:

```python
from starlette.applications import Starlette
from starlette.responses import StreamingResponse
import httpx, uvicorn

UPSTREAM = "http://127.0.0.1:6288/sse"
app = Starlette()

@app.route("/messages/")
async def sse_alias(request):
    async with httpx.AsyncClient() as c:
        r = await c.get(UPSTREAM, timeout=None)
        return StreamingResponse(r.aiter_raw(), media_type="text/event-stream")

uvicorn.run(app, host="127.0.0.1", port=6289)
# Then use http://127.0.0.1:6289/messages/ as SERVER_URL
```

---

## Verify

* In **mcpgateway** UI/API: `GET /gateways` → should show **Watsonx Chat Agent** with **reachable=true** and recent **lastSeen**.
* In **Matrix Hub** catalog: you’ll see the install result with the `gateway.register` step OK.

That’s it—you’re wired up. 🚀
