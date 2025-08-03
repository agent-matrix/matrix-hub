# Matrix-Hub — Ingesting MCP Servers, Tools & Agents

This guide shows how to **publish** MCP servers/tools/agents and how to **register** them into Matrix-Hub and the MCP-Gateway.

> **Two ways to add content**
>
> 1) **Catalog flow (recommended, scalable)**  
>    Maintain a public `matrix/index.json` (your catalog) and let Matrix-Hub ingest it, writing **Entities** into the Hub **database**, then optionally “install” to register with the **MCP-Gateway**.
>
> 2) **Direct install (quick test)**  
>    POST a manifest inline to `/catalog/install` to skip catalog/ingest.

Matrix-Hub validates manifests against the JSON Schemas in `schemas/` and stores **Entities** (servers/tools/agents) in the Hub DB (SQLite by default; Postgres recommended for prod).

---

## What lives where?

**Side server (your content repo)**
```

<your-content-repo>/
└─ matrix/
├─ index.json                     # your catalog (ingested by the Hub)
├─ hello-server.manifest.json     # example mcp\_server manifest
├─ hello-tool.manifest.json       # (optional) example tool
└─ hello-agent.manifest.json      # (optional) example agent

```

**Matrix-Hub repo**
```

matrix-hub/
├─ scripts/
│  └─ init.py                        # generates/maintains matrix/index.json (3 supported shapes)
├─ examples/
│  ├─ add\_hello-sse-server.sh        # concrete example: Hello SSE server (index + optional register)
│  └─ add\_mcp\_server.sh              # generic: add any mcp\_server by URL (index + optional register)
├─ matrix/
│  └─ index.json                     # local catalog if you keep content here
└─ src/
├─ services/ingest.py             # pulls index → upserts Entities in DB
├─ services/install.py            # “install”: runs mcp\_registration
├─ services/gateway\_client.py     # calls MCP-Gateway admin API
└─ routes/…                       # /remotes, /ingest, /catalog/install

```

**Hub database (by default):** `./data/catalog.sqlite`  
Override with `DATABASE_URL`, e.g., `postgresql+psycopg://user:pass@host/dbname`.

---

## Prerequisites

- Matrix-Hub running locally or in a container (reachable at `HUB_URL`, e.g., `http://127.0.0.1:7300`).
- Hub admin token in env as `ADMIN_TOKEN` (matches `API_TOKEN` in Hub `.env` if set).
- If you want Hub to auto-register your servers into MCP-Gateway, set in the **Hub process** env:
  - `MCP_GATEWAY_URL`
  - `MCP_GATEWAY_TOKEN`
- `curl`, `jq`, and Python 3 installed (for the helper scripts).

> **Networking tip (Docker):** If your MCP server runs on your host at `127.0.0.1:8000` but Hub runs in a container, the container cannot reach your host’s `127.0.0.1`. Use `http://host.docker.internal:8000/` (on Docker Desktop), a LAN IP, or a compose service name reachable from the container network.

---

## Manifests — minimal examples

### MCP Server (SSE) — `matrix/hello-server.manifest.json`
```json
{
  "schema_version": 1,
  "type": "mcp_server",
  "id": "hello-sse-server",
  "name": "Hello World MCP (SSE)",
  "version": "0.1.0",
  "summary": "Minimal SSE server exposing one 'hello' tool.",
  "homepage": "https://github.com/your/repo",
  "mcp_registration": {
    "server": {
      "name": "hello-sse-server",
      "description": "Hello SSE server",
      "transport": "SSE",
      "url": "http://host.docker.internal:8000/messages/"
    }
  }
}
```

### (Optional) Tool — `matrix/hello-tool.manifest.json`

```json
{
  "schema_version": 1,
  "type": "tool",
  "id": "hello-tool",
  "name": "Hello Tool",
  "version": "1.0.0",
  "summary": "Echoes hello.",
  "implementation": {
    "runtime": "python",
    "entrypoint": "python -m hello_tool.main"
  }
}
```

### (Optional) Agent — `matrix/hello-agent.manifest.json`

```json
{
  "schema_version": 1,
  "type": "agent",
  "id": "assistant-basic",
  "name": "Assistant (Basic)",
  "version": "0.1.0",
  "summary": "Simple agent that can call tools.",
  "capabilities": { "tools": ["hello-tool"] },
  "config": {
    "model": "gpt-4o-mini",
    "temperature": 0.3
  }
}
```

---

## Option A — Catalog flow (recommended for scale)

You keep a **catalog index** (`matrix/index.json`) that lists **entities** by `manifest_url`. Hub reads this URL, fetches the manifests, validates them, and persists **Entities** into the DB.

### 1) Initialize an empty index

From the Matrix-Hub repo root:

```bash
python3 scripts/init.py init-empty
# → creates matrix/index.json (default "items" shape)
```

`scripts/init.py` supports 3 shapes the Hub ingestor understands:

* **A)** `{"manifests": ["https://.../a.yaml", ...]}`
* **B)** `{"items": [{"manifest_url":"https://.../a.yaml"}, ...]}`  ← default, recommended
* **C)** `{"entries": [{"path":"a.json", "base_url":"https://host/matrix/"}]}`

If you prefer a different shape:

```bash
python3 scripts/init.py init-empty --shape manifests   # or --shape entries
```

### 2) Add the Hello SSE server to the index (by URL)

> `add-url` only needs the manifest URL; the Hub will read id/version from the manifest during ingest/install.

```bash
python3 scripts/init.py add-url \
  --manifest-url "https://raw.githubusercontent.com/<user>/<repo>/<ref>/matrix/hello-server.manifest.json"
```

This yields a `matrix/index.json` like:

```json
{
  "items": [
    { "manifest_url": "https://raw.githubusercontent.com/<user>/<repo>/<ref>/matrix/hello-server.manifest.json" }
  ],
  "meta": { "format": "matrix-hub-index", "version": 1, "generated_by": "scripts/init.py" }
}
```

> For large catalogs (millions of entries), shard into `index-0001.json`, `index-0002.json`, … and list those URLs somewhere you can iterate over, or extend the ingestor to follow shards. Alternatively: call `/ingest` once per shard URL.

### 3) Tell the Hub about your index URL and ingest

```bash
export HUB_URL=http://127.0.0.1:7300
export ADMIN_TOKEN=your-admin-token
export INDEX_URL=https://raw.githubusercontent.com/<user>/<repo>/<ref>/matrix/index.json

# Register the remote (idempotent)
curl -sS -X POST "$HUB_URL/remotes" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"url\":\"$INDEX_URL\"}" | jq .

# Trigger ingest now (scheduler also runs periodically)
curl -sS -X POST "$HUB_URL/ingest" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"url\":\"$INDEX_URL\"}" | jq .
```

### 4) Install (executes `mcp_registration` → registers with MCP-Gateway)

If you know the UID (`type:id@version`), you can install by UID **after ingest**:

```bash
curl -sS -X POST "$HUB_URL/catalog/install" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"id":"mcp_server:hello-sse-server@0.1.0","target":"./"}' | jq .
```

* The **Entity** is already in the DB (from ingest).
* The install step re-loads the manifest and, if it contains `mcp_registration.server`, calls the MCP-Gateway admin API to register the server.

---

## Option B — Direct install (skip catalog/ingest)

Useful for local testing or when you don’t want to publish index/manifest yet. POST the manifest **inline**:

```bash
curl -sS -X POST "$HUB_URL/catalog/install" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "target": "./",
    "manifest": {
      "schema_version": 1,
      "type": "mcp_server",
      "id": "hello-sse-server",
      "name": "Hello World MCP (SSE)",
      "version": "0.1.0",
      "mcp_registration": {
        "server": {
          "name": "hello-sse-server",
          "transport": "SSE",
          "url": "http://host.docker.internal:8000/messages/"
        }
      }
    }
  }' | jq .
```

---

## Helper scripts

We’ve added two convenience scripts under `examples/` in the Matrix-Hub repo.

### 1) `examples/add_hello-sse-server.sh`

Adds the Hello SSE example to the **index**, and optionally pushes it through **remote → ingest → install** into the Hub DB.

```bash
# Index only:
examples/add_hello-sse-server.sh

# Index + push into Hub (DB):
HUB_URL=http://127.0.0.1:7300 ADMIN_TOKEN=your-admin-token \
examples/add_hello-sse-server.sh --register
```

* Internally calls:

  * `python3 scripts/init.py init-empty` (if needed)
  * `python3 scripts/init.py add-url --manifest-url "<hello manifest url>"`
  * If `--register`, then:

    * `POST /remotes` with the derived `…/matrix/index.json`
    * `POST /ingest` for the same URL
    * `POST /catalog/install` with UID `mcp_server:hello-sse-server@0.1.0`

### 2) `examples/add_mcp_server.sh`

Generic for **any** MCP server manifest URL. If you pass `--register` and omit `--id/--version`, it will fetch the manifest and auto-discover them.

```bash
# Index only (default hello example used if --manifest-url omitted):
examples/add_mcp_server.sh \
  --manifest-url "https://raw.githubusercontent.com/<user>/<repo>/<ref>/matrix/hello-server.manifest.json"

# Index + push into Hub (auto-discover id/version):
HUB_URL=http://127.0.0.1:7300 ADMIN_TOKEN=your-admin-token \
examples/add_mcp_server.sh \
  --manifest-url "https://raw.githubusercontent.com/<user>/<repo>/<ref>/matrix/hello-server.manifest.json" \
  --register

# Index + push into Hub (explicit id/version):
HUB_URL=http://127.0.0.1:7300 ADMIN_TOKEN=your-admin-token \
examples/add_mcp_server.sh \
  --manifest-url "https://raw.githubusercontent.com/<user>/<repo>/<ref>/matrix/hello-server.manifest.json" \
  --id hello-sse-server --version 0.1.0 --register
```

---

## How the Hub processes your content

* **`POST /remotes`** — store the index URL (for ingestion).
* **`POST /ingest`** — download the index JSON, extract manifest URLs, fetch & validate each manifest, **upsert Entity rows** (type, id, version, metadata) into the Hub **DB**.
* **`POST /catalog/install`** — for a given Entity UID (`type:id@version`) or inline manifest, execute the **install plan** (e.g., `mcp_registration`) via `src/services/install.py`. For MCP servers, the install step calls the **MCP-Gateway admin API** to register the server.

---

## Best practices for scale

* **Keep the index small:** Use `manifest_url` instead of embedding large manifests. Shard the index and host it on a static origin (GitHub raw, S3, CDN).
* **Use Postgres:** Switch `DATABASE_URL` to Postgres for concurrency and size (e.g., `postgresql+psycopg://user:pass@host/dbname`).
* **Batch ingestion:** Call `/ingest` per shard, or extend the ingestor to follow `"shards"` recursively.
* **Idempotency:** Re-posting the same remote / re-ingesting is safe — Entities are upserted by `(type,id,version)`.
* **Networking:** For containerized Hub/Gateway, expose MCP servers at addresses reachable from the container network (service DNS, `host.docker.internal`, or LAN IP).

---

## Troubleshooting

* **Ingest says “No compatible ingest function found”**
  Your `index.json` shape isn’t recognized. Use one of the supported shapes; the simplest is the “items” shape:

  ```json
  {
    "items": [
      { "manifest_url": "https://.../matrix/hello-server.manifest.json" }
    ],
    "meta": { "format": "matrix-hub-index", "version": 1 }
  }
  ```

  Or switch to **Direct install** while you iterate.

* **Server unreachable from Hub**
  If Hub runs in Docker, replace `http://127.0.0.1:8000/messages/` with `http://host.docker.internal:8000/messages/` (or proper host/network address).

* **Auth failures**
  Ensure requests include `Authorization: Bearer $ADMIN_TOKEN`, where `ADMIN_TOKEN` matches the Hub’s `API_TOKEN`.

* **Gateway registration fails**
  Verify `MCP_GATEWAY_URL` and `MCP_GATEWAY_TOKEN` are set in the **Hub** environment; check Hub logs for the outbound call result.

---

## Quick local demo with the Hello SSE server

1. **Run your server** (from your server project):

```bash
uvicorn agents.hello_world.server_sse:app --host 127.0.0.1 --port 8000
```

2. **Add to index & push into Hub** (from Matrix-Hub repo root):

```bash
HUB_URL=http://127.0.0.1:7300 ADMIN_TOKEN=your-admin-token \
examples/add_hello-sse-server.sh --register
```

3. **Verify in Hub logs**: you should see ingest upserts and a successful MCP-Gateway registration for `hello-sse-server`.

---

## CI idea (content repo)

* On every tagged release:

  1. Generate/update `matrix/index.json` (via a small Python script or `scripts/init.py`).
  2. Commit and push the updated index to a public URL (GitHub raw/Pages, S3, CDN).
  3. Optionally call your Hub’s `/ingest` endpoint (or rely on the Hub’s scheduler).

That’s it!
Use **Catalog flow** for production scale; use **Direct install** for fast local tests. Keep your manifests and `matrix/index.json` in a content repo, and let Matrix-Hub handle ingestion, persistence, and Gateway registration.
