# MatrixHub: Ingest & Install MCP Servers, Tools, and Agents

This guide shows the **supported, working** ways to bring MCP servers/agents/tools into **MatrixHub** and register them in **MCP-Gateway**. It includes ready-to-run scripts and clarifies **SSE URL normalization, token auth, ports, and idempotency**.

> **TL;DR (run from repo root)**
>
> * **Option A – Local manifest → direct MCP-Gateway registration (no HTTP server):**
>   `examples/install_watsonx_local.sh`
> * **Option B – Serve repo over localhost + install via MatrixHub (/catalog/install):**
>   `examples/serve_and_ingest_watsonx.sh`
> * **Option C – Local file index (no HTTP server) + install via MatrixHub:**
>   `examples/ingest_local_index.sh`

---

## 1) Prerequisites

* **MatrixHub** API running locally on **port 443**
  (the helper scripts auto-detect whether it’s HTTP or HTTPS on `127.0.0.1:443`).
* **MCP-Gateway** running locally on **port 4444**.
* CLI tools: `bash`, `curl`, `jq`, `python`.
* Your **MCP server** (Watsonx example) running with **SSE at `/sse`**:

  * We provide `examples/start-watsonx-agent.sh` (starts Uvicorn at `http://127.0.0.1:6288` and exposes `http://127.0.0.1:6288/sse`).

### Environment (recommended .env entries)

These are the simplest, most reliable values the scripts use:

```bash
# MatrixHub → shows up in the UI and accepts /catalog/install
HUB_BASE=http://127.0.0.1:443

# MCP-Gateway admin API used by installers/MatrixHub
MCP_GATEWAY_URL=http://127.0.0.1:4444
# Accepts raw JWT or already prefixed values (the scripts add “Bearer ” if missing)
MCP_GATEWAY_TOKEN=<your-admin-JWT-or-Bearer-token>

# (Optional) Lets MatrixHub derive tools from MCP where supported
DERIVE_TOOLS_FROM_MCP=true
```

> **Why `/sse`?** Historically, some installers rewrote SSE bases to `/messages/`. All scripts below **force** `server.url` to end in `/sse` and **remove** `transport` to prevent rewrites and 4xx/5xx on registration.

---

## 2) Assets in this repo

```
examples/
├─ manifests/
│  └─ watsonx.manifest.json         # Example MCP server manifest (base URL; scripts patch to /sse)
├─ index.json                        # Remote-style index (use relative paths!)
├─ local_index.json                  # File index for Option C
├─ start-watsonx-agent.sh            # Helper to run the Watsonx agent locally
├─ install_watsonx_local.sh          # Option A
├─ serve_and_ingest_watsonx.sh       # Option B
└─ ingest_local_index.sh             # Option C
```

---

## 3) Option A — One-shot install from a **local manifest** (direct to MCP-Gateway)

**Use when** you want to register directly into MCP-Gateway without spinning up a local HTTP server.

**Script:** `examples/install_watsonx_local.sh`

What it does:

1. Reads `examples/manifests/watsonx.manifest.json`.
2. Patches `mcp_registration.server.url` → **`…/sse`** and removes `transport`.
3. (Non-fatal) preflights the SSE URL.
4. Upserts **Tool → Resources → Prompts → Federated Gateway** into MCP-Gateway:

   * Treats **409 Conflict** as “already exists”.
   * If resources/prompts already exist, it looks them up to get their **numeric IDs** (required by gateways).

Run:

```bash
chmod +x examples/install_watsonx_local.sh
bash examples/install_watsonx_local.sh
```

**Success signs**

* “✓ Tool upserted…”, “✓ Resource upserted… → id=…”, and
  “✅ Gateway upserted (HTTP 200/201/409)”.

---

## 4) Option B — Serve repo via localhost & **install via MatrixHub** (/catalog/install)

**Use when** you want to emulate remote ingest using a tiny local web server.

**Script:** `examples/serve_and_ingest_watsonx.sh`

What it does:

1. Serves your repo at `http://127.0.0.1:<free-port>/`.

   * If `8000` is busy, it chooses another free port (8001–8020) and **rewrites relative links** from the index to that port.
2. Loads `examples/index.json` (**use relative paths**; see §5).
3. For each manifest:

   * Patches URL → **`/sse`**, removes `transport`.
   * (Non-fatal) preflights the SSE URL.
   * Calls MatrixHub **`/catalog/install`** (auth auto-detected; HTTP/HTTPS on `:443` auto-probed).

Run:

```bash
chmod +x examples/serve_and_ingest_watsonx.sh
bash examples/serve_and_ingest_watsonx.sh
```

**Success signs**

* “✔ Found index… (HTTP 200)”
* For each manifest: “✓ SSE reachable (HTTP 200)” (nice to have),
  “↳ POST …/catalog/install → HTTP 200/201”, “✅ install ok”.

---

## 5) Option C — **Local file index** (no HTTP server) + install via MatrixHub

**Use when** you want to process a local index file directly (without running a server).

**Inputs**

`examples/local_index.json`:

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
2. Resolves each manifest (supports file paths and http(s) URLs).
3. Patches URL → **`/sse`** and removes `transport`.
4. Calls MatrixHub **`/catalog/install`** for each manifest.

Run:

```bash
chmod +x examples/ingest_local_index.sh
bash examples/ingest_local_index.sh
```

---

## 6) Correct shapes (index + manifest)

### `examples/index.json` (**use relative paths**)

```json
{
  "manifests": [
    "examples/manifests/watsonx.manifest.json"
  ]
}
```

> Don’t hardcode `http://127.0.0.1:8000/...`. The server might have to use `8001+`, and the script will rewrite relative URLs to whatever port it picked.

### `examples/manifests/watsonx.manifest.json` (base URL; scripts patch to `/sse`)

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

> The scripts **change** `url` → `http://127.0.0.1:6288/sse` and **remove** `transport` before posting anywhere.

---

## 7) Quick runbook (end-to-end)

1. **Start your Watsonx MCP server**:

   ```bash
   bash examples/start-watsonx-agent.sh
   # Logs should show Uvicorn at http://127.0.0.1:6288 and HEAD /sse returns 200.
   ```

2. **Export / confirm env** (usually set via `.env`):

   ```bash
   export MCP_GATEWAY_URL=http://127.0.0.1:4444
   export MCP_GATEWAY_TOKEN=<your-admin-JWT-or-Bearer-token>
   export HUB_BASE=http://127.0.0.1:443
   ```

3. **Install** using one of the options:

   * Direct to Gateway: `bash examples/install_watsonx_local.sh`
   * Serve + Hub install: `bash examples/serve_and_ingest_watsonx.sh`
   * Local file index + Hub install: `bash examples/ingest_local_index.sh`

4. **Verify in MCP-Gateway**:

   ```bash
   curl -s http://127.0.0.1:4444/gateways | jq '.[] | {name, url, reachable}'
   curl -s http://127.0.0.1:4444/tools    | jq '.[] | {id, name, integrationType, requestType}'
   curl -s http://127.0.0.1:4444/resources | jq '.[] | {id, name, uri}'
   ```

   You should see your **federated gateway** (URL ends with `/sse`) and the **tool** (e.g., `watsonx-chat`).
   Resources should have **numeric `id`** values (the scripts resolve them automatically).

---

## 8) What MatrixHub actually does on `/catalog/install`

When you use Options **B** or **C**, the script posts to MatrixHub:

```http
POST {HUB_URL}/catalog/install
Content-Type: application/json

{
  "id": "mcp_server:watsonx-agent@0.1.0",
  "target": "./",
  "manifest": { ...patched manifest... }
}
```

MatrixHub then:

* Registers **Tool** → `/tools`
* Registers **Resources** → `/resources` (returns **numeric IDs**)
* Registers **Prompts** → `/prompts` (numeric IDs)
* Registers **Federated Gateway** → `/gateways` (when `server.url` present)
  or **Virtual Server** → `/servers` (when no URL present)

All actual HTTP calls are done via the internal `gateway_client.py`, with retries and idempotent behavior.

---

## 9) Troubleshooting (real-world fixes we baked in)

* **401 from Gateway**
  Token missing/invalid. Set `MCP_GATEWAY_TOKEN` (or `GATEWAY_TOKEN`). The scripts add “Bearer ” if you don’t.

* **“wrong version number” / SSL issues**
  You posted HTTPS to an HTTP Hub (or vice versa). The scripts **probe `/health`** on `127.0.0.1:443` and pick the correct scheme automatically.

* **SSE preflight times out**
  Some SSE servers only emit on first event and don’t return quick headers. Preflight is **non-fatal**; we continue. Still, you should see Uvicorn output and 200s for `HEAD /sse` while the agent is running.

* **Index 404 or “port 8000 already in use”**
  Use **relative paths** in `examples/index.json`. The script chooses a free local port (8001–8020) and rewrites the links.

* **“Could not resolve numeric resource id …”**
  On 409 Conflict, the script does `GET /resources` and matches by `name`/`uri`/stringified `id` to fetch the **numeric** id. If names/uris don’t match, adjust the manifest so they do.

* **Shell variable collision (`UID` is readonly)**
  Don’t use `UID` as a shell variable. Our scripts use `ENTITY_UID` instead.

---

## 10) Notes for production / future enhancements

* Keep `/catalog/install` fast under reverse proxies: off-path heavy work, **202 + status polling**, or bounded parallel upserts.
  (We already apply small, safe parallelism in `gateway_client.py` for bulk resources/prompts.)
* Always normalize SSE URLs to **`/sse`** and **remove `transport`** if you’re posting manifests yourself.
* Prefer **relative** manifest refs in indexes (lets local servers rewrite ports transparently).

---

That’s it! With these three scripts and shapes, you can reliably bring MCP servers into **MatrixHub** and **MCP-Gateway** in local dev — and you’ve got the exact rules to keep future ingestion/installation features stable.
