# Matrix Hub ⇄ MCP-Gateway ingestion & registration — **Definitive How-To**

Below is a clean, battle-tested flow for getting your **Watsonx MCP server** (or any MCP server) into **Matrix Hub** and **MCP-Gateway**, using your `index.json` and `manifest`. It captures all the fixes we made (SSE normalization, port rewrites, HTTP/HTTPS detection, idempotent upserts, auth, and numeric IDs).

---

## 0) Prereqs

* **Matrix Hub** running locally on **port 443**
  `.env` must include:

  ```env
  HOST=0.0.0.0
  PORT=443
  MCP_GATEWAY_URL=http://127.0.0.1:4444
  MCP_GATEWAY_TOKEN=<your-admin-JWT or 'Bearer ...'>
  DERIVE_TOOLS_FROM_MCP=true
  ```
* **MCP-Gateway** running locally on **port 4444**, admin token valid.
* **Watsonx agent** running locally on **port 6288** with SSE at `/sse`:

  ```bash
  bash examples/start-watsonx-agent.sh
  # server logs: "Uvicorn running on http://127.0.0.1:6288" and HEAD /sse returns 200
  ```
* Tools: `jq`, `curl`, `python` available.

---

## 1) Project files (minimal correct shapes)

### `examples/index.json`

> **Use relative paths** so the helper can rewrite to the chosen serve port automatically.

```json
{
  "manifests": [
    "examples/manifests/watsonx.manifest.json"
  ]
}
```

### `examples/manifests/watsonx.manifest.json`

> Keep `server.url` pointing to the **base** (no `/sse`). The scripts will enforce `/sse` and drop `transport` to avoid the Hub’s `/messages/` rewrite.

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

---

## 2) Two supported ways to ingest

### A) **Serve + Hub install** (recommended for dev)

Runs a tiny HTTP server to expose your repo, reads `index.json`, preflights SSE, **patches URL → `/sse`**, **removes `transport`**, then posts to Hub `/catalog/install`.

```bash
bash examples/serve_and_ingest_watsonx.sh
```

**What the script handles for you**

* Chooses a free local port (8000→8020) if `8000` is busy and rewrites any `localhost` URLs in the index to that port.
* Detects if Hub at `:443` is HTTP or HTTPS and sends appropriately (handles the “wrong SSL version” pitfall).
* Preflights `http://127.0.0.1:6288/sse`. Non-2xx is tolerated (some SSE servers only open on first event), but a fast 200 is ideal.
* Calls:

  ```
  POST {HUB_URL}/catalog/install
  {
    "id": "mcp_server:watsonx-agent@0.1.0",
    "target": "./",
    "manifest": <patched manifest>
  }
  ```
* Idempotent: repeat runs won’t break things.

**Common success output**

```
✔ Found index at http://127.0.0.1:800x/examples/index.json
   ⏱ Preflight SSE: http://127.0.0.1:6288/sse
   ✓ SSE reachable (HTTP 200)
   📦 Installing mcp_server:watsonx-agent@0.1.0
   ↳ POST http://127.0.0.1:443/catalog/install → HTTP 200
   ✅ install ok
```

> If you want to **only** send manifests (no local server) use `examples/ingest_local_index.sh` with a local `examples/local_index.json`. It performs the same patching and posting to Hub, but loads manifests directly from disk.

---

### B) **Direct MCP-Gateway registration** (bypasses Hub’s registration)

If your Hub can’t register with the gateway (e.g., token/CF/network issues) or you just want full control, register directly:

```bash
bash examples/install_watsonx_local.sh
```

**What it does**

1. Patches manifest URL → `/sse` and drops `transport`.
2. **Tool**: `POST /tools` (idempotent; 409 treated as success)
3. **Resources**: `POST /resources` (returns **numeric IDs**). On 409, it **GETs /resources** to resolve the numeric id by `name`/`id`/`uri`.
4. **Prompts** (optional): `POST /prompts` (resolve numeric IDs similarly)
5. **Federated Gateway**: `POST /gateways` with:

   ```json
   {
     "name": "...",
     "description": "...",
     "url": "http://127.0.0.1:6288/sse",
     "associated_tools": ["watsonx-chat"],
     "associated_resources": [<numeric ids>],
     "associated_prompts": [<numeric ids>]
   }
   ```

**Auth header**: `Authorization: Bearer <MCP_GATEWAY_TOKEN>` (the script auto-adds `Bearer` if missing)

**Common success output**

```
▶️  Registering components directly with MCP-Gateway at http://127.0.0.1:4444
✓ Tool upserted (watsonx-chat) [HTTP 409]
✓ Resource upserted (Watsonx MCP server source → id=7) [HTTP 409]
✓ Federated gateway upserted (watsonx-mcp) [HTTP 201]
```

---

## 3) Why the scripts rewrite `/sse` and ports

* **SSE endpoint**: Your gateway expects an SSE stream URL (e.g., `http://127.0.0.1:6288/sse`). If manifests carry `transport=SSE`, Hub historically rewrote to `/messages/`. To avoid this, we **force `/sse`** and **remove `transport`**.
* **Port rewrites**: If `examples/index.json` hard-codes `http://127.0.0.1:8000/...` but port 8000 is taken, the server picks 8001+ and rewrites references so the fetch **doesn’t 404**. That’s why your index should use **relative paths**.

---

## 4) Minimal API cheatsheet (MCP-Gateway)

* **Auth**: `Authorization: Bearer <token>` (or include “Bearer ” in the env var)
* **POST /tools**

  ```json
  {
    "name": "watsonx-chat",
    "description": "Chat with IBM watsonx.ai",
    "integration_type": "MCP",
    "request_type": "SSE",
    "id": "watsonx-chat"    // optional – if supplied, 409 means already exists
  }
  ```
* **POST /resources**

  ```json
  {
    "name": "Watsonx MCP server source",
    "type": "inline",
    "uri": "file://server.py",
    "content": "Inline code or reference only",
    "id": "watsonx-agent-code" // optional
  }
  ```

  Returns `{ "id": <numeric> }`. On **409**, do `GET /resources` and match by `name` or `uri` to get the **numeric id**.
* **POST /prompts**

  ```json
  {
    "name": "my-prompt",
    "description": "",
    "template": "..."
  }
  ```

  Returns numeric `id`.
* **POST /gateways**

  ```json
  {
    "name": "watsonx-mcp",
    "description": "Watsonx SSE server",
    "url": "http://127.0.0.1:6288/sse",
    "associated_tools": ["watsonx-chat"],  // tool id or name
    "associated_resources": [7, 12],       // numeric ids
    "associated_prompts": [5]              // numeric ids
  }
  ```

---

## 5) Common pitfalls & fixes

* **401 from Gateway**: Token missing or invalid → set `MCP_GATEWAY_TOKEN` (or `GATEWAY_TOKEN`) in `.env`; scripts auto-prefix `Bearer`.
* **SSL “wrong version number”**: You posted **HTTPS** to a Hub running in **HTTP** → our scripts probe `/health` and auto-pick the right scheme; if posting manually, use `http://127.0.0.1:443` for the local dev Hub.
* **SSE preflight times out**: The agent isn’t running at `:6288/sse`. Start it with `examples/start-watsonx-agent.sh`. Preflight is non-fatal, but a working 200 reduces registration flakiness.
* **Manifest 404**: Your `index.json` hard-coded `:8000`, but the helper chose `:8001` because `:8000` was busy → use relative paths in `index.json`.
* **“Could not resolve numeric resource id”**: On 409 create, the script does a **GET /resources** and matches by **name / id / uri**. Ensure those fields match exactly the earlier registration.

---

## 6) Quick recipes

### Install via Hub (serve + install)

```bash
bash examples/serve_and_ingest_watsonx.sh
# watches examples/index.json, patches SSE, posts to {HUB_URL}/catalog/install
```

### Install a local manifest directly into **MCP-Gateway**

```bash
bash examples/install_watsonx_local.sh
# patches SSE, upserts: tool → resources → prompts → /gateways
```

### Install from a **local index file** without HTTP serving

```bash
bash examples/ingest_local_index.sh
# reads examples/local_index.json, patches SSE, posts to Hub /catalog/install
```

---

## 7) Verifying success

* **In Matrix Hub**: your `/catalog/install` response shows `"✅ install ok"` and a `matrix.lock.json` is written/updated.
* **In MCP-Gateway UI**:

  * **Registered Tools**: contains `watsonx-chat`
  * **Available Resources**: includes your inline/file resource with a **numeric ID**
  * **Federated Gateways**: shows `watsonx-mcp` with URL `http://127.0.0.1:6288/sse`

---

## 8) Notes for future feature work

* Keep **install endpoint** fast (under CF timeout) by:

  * **Off-path** heavy work (e.g., background job) and return **202 + status polling**; or
  * **Parallelize** resource/prompt upserts (bounded workers); our `gateway_client.py` already does safe, minor parallelization.
* Always **normalize SSE URL** to `/sse` and **remove `transport`** client-side to avoid accidental `/messages/` rewrites.
* Prefer **relative** manifest refs in indexes to allow on-the-fly port rewrites.

---

That’s the whole story. If you stick to the shapes above and run the two scripts in the right order (agent → serve+ingest or direct gateway), your Watsonx server will be visible both in **Matrix Hub** and **MCP-Gateway** every time.



## Clarifications

You’re running **three different services**, each with its own job:

1. **Matrix Hub** → `127.0.0.1:443`
   This is your catalog/API. The script posts manifests here (`/catalog/install`). It does **not** serve your example files.

2. **Watsonx MCP agent** → `127.0.0.1:6288/sse`
   This is your actual MCP server (the tool). Hub or Gateway connects to this SSE endpoint.

3. **Tiny static file server** → `127.0.0.1:8000` (or `8001` if 8000 is busy)
   This is created **only by the helper script** to serve your local `examples/index.json` and `examples/manifests/*.json` over HTTP while installing. It’s ephemeral and independent of Hub/Agent. If 8000 is taken, the script auto-picks 8001 and rewrites any localhost links to match.

So, **8000/8001 is not a bug** — it’s just a throwaway web server to make your *local* index/manifest reachable via HTTP during ingestion. Your “real” ports remain:

* Hub: **443**
* Agent (SSE): **6288**

### Why you saw that “connection refused” then success

Right after starting the tiny static server, curl can beat it by a split second → one failed attempt; the next retry gets `200`. That’s expected and harmless.

### If you don’t want 8000/8001 at all

You have two clean options:

* **Skip serving files** and install directly from disk:

  ```bash
  bash examples/install_watsonx_local.sh
  ```

  This script patches the manifest to `/sse` and POSTS it straight to the Hub (and can also register in MCP-Gateway if you use the gateway-specific script we fixed earlier).

* **Host the manifest somewhere already HTTP-accessible** (e.g., GitHub raw). Then your index can point to a public URL and the local static server isn’t needed.

### Best practices (you’re already doing them)

* Keep `examples/index.json` using **relative paths**, e.g.:

  ```json
  { "manifests": ["examples/manifests/watsonx.manifest.json"] }
  ```

  That way, if the helper server lands on 8001, links still resolve.

* Ensure the agent is up on **6288/sse** (your logs show it is), and the Hub is reachable on **443**.


