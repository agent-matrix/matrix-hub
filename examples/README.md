# MatrixHub: Ingest & Install MCP Servers, Tools, and Agents

This guide shows **all supported ways to bring MCP servers/agents/tools into MatrixHub** and register them in **mcpgateway**. It includes ready‑to‑run scripts and explains what MatrixHub does behind the scenes.

> **TL;DR scripts** (run from repo root):
>
> * Option A (local manifest → one POST): `examples/install_watsonx_local.sh`
> * Option B (serve repo via localhost + ingest index): `examples/serve_and_ingest_watsonx.sh`
> * Option C (local file index without HTTP): `examples/ingest_local_index.sh`

---

## 1) Prerequisites

* **MatrixHub** API running (default: `http://127.0.0.1:7300`).
* **mcpgateway** running (default admin API used by MatrixHub).
* CLI tools: `bash`, `curl`, `jq`, `python`.
* Your MCP server running (SSE **`/sse`** endpoint recommended).

### Environment (MatrixHub)

Set these in MatrixHub’s environment:

```bash
# Where MatrixHub will POST installs/registrations
export MCP_GATEWAY_URL=http://127.0.0.1:4444
# Auth to talk to mcpgateway (choose one method)
export JWT_SECRET_KEY=my-test-key
export BASIC_AUTH_USERNAME=admin
# or use a pre-minted
# export MCP_GATEWAY_TOKEN=eyJhbGciOi...
```

> **Why `/sse`?** MatrixHub historically normalized SSE bases to `/messages/`. The bundled scripts here **force** the manifest URL to `/sse` and drop the `transport` field, so MatrixHub won’t rewrite the URL.

---

## 2) Assets in this repo

```
examples/
├─ manifests/
│  └─ watsonx.manifest.json         # Example MCP server manifest
├─ local_index.json                  # File index that references the manifest
├─ install_watsonx_local.sh          # Option A script
├─ serve_and_ingest_watsonx.sh       # Option B script
└─ ingest_local_index.sh             # Option C script
```

---

## 3) Option A — One‑shot install with a local manifest

**Use when** you have a manifest file locally and want a single call to MatrixHub.

**Script:** `examples/install_watsonx_local.sh`

What it does:

1. Reads your local manifest `examples/manifests/watsonx.manifest.json`.
2. Patches `mcp_registration.server.url` to end with **`/sse`** and removes `transport`.
3. (Non-fatal) preflight of the SSE URL.
4. POSTs to **`/catalog/install`** — MatrixHub then registers tool/resources/prompts and the **Federated Gateway** in mcpgateway.

Run:

```bash
chmod +x examples/install_watsonx_local.sh
bash examples/install_watsonx_local.sh
```

Expected result: the gateway appears in mcpgateway and is reachable.

---

## 4) Option B — Serve repo via localhost & ingest an index

**Use when** you want to simulate remote ingest using a local HTTP server.

**Script:** `examples/serve_and_ingest_watsonx.sh`

What it does:

1. Serves your repo root over `http://127.0.0.1:8000/`.
2. Loads `http://127.0.0.1:8000/examples/index.json`.
3. Extracts manifest URLs; for each manifest it patches URL → **`/sse`**, removes `transport`.
4. Calls **`/catalog/install`** per manifest (equivalent outcome to ingest+install).

Run:

```bash
chmod +x examples/serve_and_ingest_watsonx.sh
bash examples/serve_and_ingest_watsonx.sh
```

> Note: Some MatrixHub builds don’t expose a `/remotes/ingest` endpoint. This script mirrors ingest behavior client‑side and uses `/catalog/install` for reliability.

---

## 5) Option C — Local file index (no HTTP server)

**Use when** you want to process a local index file directly.

**Inputs**

* `examples/local_index.json`

```json
{
  "manifests": [
    "examples/manifests/watsonx.manifest.json"
  ]
}
```

**Script:** `examples/ingest_local_index.sh`

What it does:

1. Reads `examples/local_index.json`.
2. Resolves each manifest path (supports `http(s)` and filesystem paths).
3. Patches URL → **`/sse`**, removes `transport`.
4. Calls **`/catalog/install`** for each manifest.

Run:

```bash
chmod +x examples/ingest_local_index.sh
bash examples/ingest_local_index.sh
```

---

## 6) Verifying the registration

After running any option:

```bash
# Gateways list (should include your server and show reachable: true)
curl -s http://127.0.0.1:4444/gateways | jq .

# Tools (global + MCP‑discovered where applicable)
curl -s http://127.0.0.1:4444/tools | jq '.[] | {id, name, integrationType, requestType}'
```

If your server exposes a tool named `chat`, you should see it after the gateway handshake/discovery finishes.

---

## 7) What MatrixHub does under the hood

**On install (Option A/B/C, via `/catalog/install`):**

* `src/services/install.py::install_entity()` → `_maybe_register_gateway(manifest)`

  * Registers **tool** → `/tools`
  * Registers **resources** → `/resources`
  * Registers **prompts** → `/prompts`
  * If `server.url` exists → **`/gateways`** (Federated Gateway), otherwise → `/servers` (Virtual Server)
  * Re‑affirms the gateway idempotently
* Network calls are made through `src/services/gateway_client.py` helpers:

  * `register_gateway`, `register_server`, `register_tool`, `register_resources`, `register_prompts`

**On ingest (remote indexes)**

* `src/services/ingest.py::_ingest_remote()` recognizes `type == "mcp_server"` and best‑effort calls `register_gateway(...)` (SSE URL normalization is performed client‑side by our scripts).

---

## 8) Troubleshooting

### A) `502` or `400` around `/messages/` or missing Content‑Type

* Cause: Your MCP server is serving SSE at **`/sse`**, while MatrixHub/gateway tried `/messages/`.
* Fix: Use the provided scripts — they **force `/sse`** and remove `transport`, preventing rewrites.

  * Alternatively, proxy `/messages/` → `/sse` (nginx/Caddy) if you prefer the legacy path.

### B) `Tool invocation failed: 'NoneType' object has no attribute 'auth_value'`

* Usually means the tool is registered but **no working federated gateway** behind it.
* Fix: Ensure gateway registration succeeded (see verification), and that your server is running.

### C) SSE preflight shows timeout

* Normal: many SSE servers keep the connection open and don’t send a quick 2xx.
* The scripts continue regardless; this preflight is just a helpful probe.

### D) `/remotes/ingest` returns 404

* Some MatrixHub builds don’t expose that route; our Option B script mimics ingest and uses `/catalog/install` for the same outcome.

---

## 9) Example manifest (watsonx)

`examples/manifests/watsonx.manifest.json` (original — scripts patch URL/transport on the fly):

```json
{
  "type": "mcp_server",
  "id": "watsonx-agent",
  "name": "Watsonx Chat Agent",
  "version": "0.1.0",
  "description": "An MCP server that chats via IBM watsonx.ai.",
  "mcp_registration": {
    "tool": {
      "id": "watsonx-chat",
      "name": "watsonx-chat",
      "description": "Chat with IBM watsonx.ai",
      "integration_type": "MCP"
    },
    "resources": [
      {
        "id": "watsonx-agent-code",
        "name": "Watsonx MCP server source",
        "type": "inline",
        "uri": "file://server.py",
        "content": "Inline code or reference only"
      }
    ],
    "prompts": [],
    "server": {
      "name": "watsonx-mcp",
      "description": "Watsonx SSE server",
      "transport": "SSE",
      "url": "http://127.0.0.1:6288/",
      "associated_tools": ["watsonx-chat"],
      "associated_resources": ["watsonx-agent-code"],
      "associated_prompts": []
    }
  }
}
```

> **Scripts will patch:** set `server.url` → `http://127.0.0.1:6288/sse` and remove `server.transport`.

---

## 10) Quick runbook

1. Start your MCP server:

   ```bash
   python server.py    # logs should show http://127.0.0.1:6288/sse
   ```
2. Export MatrixHub → mcpgateway env vars (see §1).
3. Run Option A/B/C script.
4. Verify on mcpgateway:

   ```bash
   curl -s http://127.0.0.1:4444/gateways | jq '.[] | {name, url, reachable}'
   curl -s http://127.0.0.1:4444/tools | jq '.[] | {id, name, integrationType}'
   ```


