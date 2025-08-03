# Matrix Hub — Quick Start (Local Ingest & Install)

This is the **definitive, step-by-step** guide to add MCP servers/tools/agents to **Matrix-Hub** on your local machine.
No prior knowledge is required — we’ll explain every step and show **copy-paste ready** commands.

You’ll learn **two ways** to get content into Matrix-Hub:

* **A) Catalog flow (recommended for scale)**
  You publish an `index.json` (and your manifests) over **HTTP**. The Hub **downloads** that URL, parses it, writes entities into the **database**, and then you “install” (register into the **MCP-Gateway**).
* **B) Direct install (quick local test)**
  You call `/catalog/install` with an ID (and optionally an inline manifest), skipping catalog/ingest.

> ### Why do I need `python3 -m http.server 8001`?
>
> Matrix-Hub must **download** your `matrix/index.json` and manifests via **HTTP**.
> It cannot read local files from your disk directly.
> For local development, the easiest way is:
>
> ```bash
> python3 -m http.server 8001
> ```
>
> This serves your folder over HTTP at `http://127.0.0.1:8001/`.
> If your files are already published on the Internet (GitHub raw/S3/CDN), **you don’t need** this local HTTP server.

---

## 0) Start Matrix-Hub locally

From the **Matrix-Hub repo root**:

```bash
# One-time setup
make setup

# Start the API server (port 7300)
make dev
```

Verify that it’s up in another terminal:

```bash
curl -sS http://127.0.0.1:7300/health
# expect 200 OK, JSON body
```

> **.env note**: If you use `.env`, it will be automatically loaded by `make dev`.
> **Auth note**: For protected endpoints, set `API_TOKEN=<token>` in `.env` and pass `-H "Authorization: Bearer <token>"` to curl.

---

## 1) Get an admin token & set HUB\_URL (the **right way**)

We provide a helper to get an admin token and endpoint:

```bash
make gateway-token
```

You’ll see something like:

```
### Generating MCP Gateway Admin Token & Hub Endpoint ###
⏳ Minting admin JWT for user 'admin'...
✅ Token and endpoint prepared. Use 'eval' to export them.
export ADMIN_TOKEN='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...'
export HUB_ENDPOINT='0.0.0.0:7300'
```

Now **export** those two values (copy/paste them exactly):

```bash
export ADMIN_TOKEN='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...'
export HUB_ENDPOINT='0.0.0.0:7300'
```

Normalize `HUB_URL` so curl can use it:

```bash
# If HUB_ENDPOINT is "0.0.0.0:7300", convert it to "http://127.0.0.1:7300"
if [[ "$HUB_ENDPOINT" == 0.0.0.0:* ]]; then
  export HUB_URL="http://127.0.0.1:${HUB_ENDPOINT##*:}"
else
  export HUB_URL="http://${HUB_ENDPOINT}"
fi

echo "HUB_URL=$HUB_URL"
# -> HUB_URL=http://127.0.0.1:7300
```

> **Why not 0.0.0.0?** That’s a **bind** address, not a client URL. Always use `127.0.0.1:7300` (or your LAN IP/hostname).

---

## 2) Pick your flow

### **Option A — Catalog flow (recommended for scale)**

You **host**:

```
<content-repo>/
└─ matrix/
   ├─ index.json                  # your catalog (Hub downloads this)
   └─ hello-server.manifest.json  # example server manifest
```

Matrix-Hub **fetches** your `index.json`, parses it, then fetches each `manifest_url` and writes **Entities** into the Hub **DB**.

> For **local dev**, host `matrix/` via:
>
> ```bash
> python3 -m http.server 8001
> ```
>
> Your **index** will be at: `http://127.0.0.1:8001/matrix/index.json`.

### **Option B — Direct install (quick test)**

You skip `index.json` and ingestion. You call `/catalog/install` with:

* `"id": "mcp_server:your-id@version"`
* Optionally an inline `"manifest": {...}` to ensure fields.

This is great for quick tests, but **not** for managing thousands of entries.

---

## 3A) Catalog flow — Initialize a correct index and serve it

> The ingestor supports exactly **one** of these top-level keys in `index.json`:
>
> * Form A: `"manifests"` — `{"manifests": ["https://.../x.manifest.json", ...]}`
> * Form B: `"items"` — `{"items": [{"manifest_url": "https://.../x.manifest.json"}, ...]}`
> * Form C: `"entries"` — `{"entries": [{"path":"x.manifest.json","base_url":"https://host/matrix/"}]}`
>
> If you use `entities` or anything else, you will see:
> **“No compatible ingest function found in src.services.ingest”**

### 3A.1) Create a **supported** index shape (`items`)

From repo root:

```bash
# Start fresh
rm -f matrix/index.json

# Create "items" index (Form B)
python3 scripts/init.py init-empty --shape items
```

### 3A.2) Add your manifest URL to the index

```bash
python3 scripts/init.py add-url \
  --manifest-url "http://127.0.0.1:8001/matrix/hello-server.manifest.json"
# (We'll start the web server in a second.)
```

This yields `matrix/index.json`:

```json
{
  "items": [
    { "manifest_url": "http://127.0.0.1:8001/matrix/hello-server.manifest.json" }
  ],
  "meta": { "format": "matrix-hub-index", "version": 1, ... }
}
```

### 3A.3) Serve the `matrix/` folder (local dev)

Open another terminal in repo root (where `matrix/` lives):

```bash
python3 -m http.server 8001
```

Now test your files are reachable:

```bash
curl -sS http://127.0.0.1:8001/matrix/index.json | jq .
curl -sS http://127.0.0.1:8001/matrix/hello-server.manifest.json | jq .
```

Export the **index URL**:

```bash
export INDEX_URL="http://127.0.0.1:8001/matrix/index.json"
```

---

## 4A) Tell Hub to ingest and install (Catalog flow)

> Ensure `HUB_URL` and `ADMIN_TOKEN` are set from **Step 1**.
> If `$HUB_URL` is empty, curl will say: “URL using bad/illegal format or missing URL”.

### 4A.1) Register the remote

```bash
curl -sS -X POST "$HUB_URL/remotes" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"url\":\"$INDEX_URL\"}" | jq .
```

Expected (idempotent) response:

```json
{
  "added": true,
  "url": "http://127.0.0.1:8001/matrix/index.json",
  "total": 1
}
```

### 4A.2) Ingest now

```bash
curl -sS -X POST "$HUB_URL/ingest" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"url\":\"$INDEX_URL\"}" | jq .
```

If the index shape is correct, you’ll see:

* `"ok": true`
* A stats summary
* Your server entity stored in the Hub DB (SQLite by default)

> If you still see **“No compatible ingest function found”**:
>
> * Your index isn’t in **items / manifests / entries** form, or
> * The Hub couldn’t fetch your index (HTTP 404/500 served an HTML page that isn’t JSON)
>
> **Fix:**
>
> ```bash
> rm -f matrix/index.json
> python3 scripts/init.py init-empty --shape items
> python3 scripts/init.py add-url --manifest-url "http://127.0.0.1:8001/matrix/hello-server.manifest.json"
> curl -sS http://127.0.0.1:8001/matrix/index.json | jq .  # ensure JSON shape is correct
> ```

### 4A.3) Install (register MCP server with Gateway)

**Install by UID**:

```bash
curl -sS -X POST "$HUB_URL/catalog/install" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"id":"mcp_server:hello-sse-server@0.1.0","target":"./"}' | jq .
```

* This loads the manifest for the Entity from the DB (created during ingest).
* If the manifest has:

  ```json
  "mcp_registration": {
    "server": {
      "name": "hello-sse-server",
      "transport": "SSE",
      "url": "http://127.0.0.1:8000/messages/"
    }
  }
  ```

  …Matrix-Hub will call MCP-Gateway’s admin API and **register** that server.

> **Gateway env**: In your Hub’s `.env`, set:
>
> ```
> MCP_GATEWAY_URL=http://127.0.0.1:4444
> MCP_GATEWAY_TOKEN=supersecret
> ```
>
> Otherwise the registration step will fail. Check the terminal running `make dev` for logs.

---

## 3B) Direct install (skip catalog/ingest)

For fast testing, you can install directly without hosting any index/manifest:

```bash
curl -sS -X POST "$HUB_URL/catalog/install" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d @- <<'JSON'
{
  "id": "mcp_server:hello-sse-server@0.1.0",
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
        "url": "http://127.0.0.1:8000/messages/"
      }
    }
  }
}
JSON
```

> Previously you might have seen **422** saying `"id" field required`.
> This payload includes `"id"` and matches your API.
> If you still get **500**:
>
> * Ensure DB is ready (`INIT_DB=true` for SQLite dev) or run `make upgrade` (Alembic).
> * Ensure `MCP_GATEWAY_URL` and `MCP_GATEWAY_TOKEN` are set in the **Hub process**.
> * Check Hub logs (where `make dev` is running) for the full traceback.

---

## 5) Make sure your MCP server is reachable

If your manifest says `"url": "http://127.0.0.1:8000/messages/"`, **run the server**:

```bash
uvicorn agents.hello_world.server_sse:app --host 127.0.0.1 --port 8000
# It exposes GET/POST on /messages/ (SSE)
```

> **Docker note**: If Hub or Gateway runs in Docker, `127.0.0.1` references the **container** itself.
> Use `http://host.docker.internal:8000/` (Docker Desktop) or a LAN IP/compose service DNS so the container can reach your server.

---

## 6) Quick connectivity test (optional helper)

We include a small checker for your **Hub health** and **index/manifest reachability & shape**:

```bash
scripts/test_remote_connection.sh \
  --index "http://127.0.0.1:8001/matrix/index.json" \
  --manifest "http://127.0.0.1:8001/matrix/hello-server.manifest.json"
```

It will print HTTP status codes and confirm if the index is in a supported shape (`items`, `manifests`, or `entries`). If both return **200** and shape is recognized, `/ingest` will work.

---

## 7) Common pitfalls (and precise fixes)

* **“URL using bad/illegal format or missing URL”**
  You didn’t set `HUB_URL`. Do **Step 1** (`make gateway-token`), export `ADMIN_TOKEN` & `HUB_ENDPOINT`, then set `HUB_URL`. Validate:

  ```bash
  echo "$HUB_URL"   # should be http://127.0.0.1:7300
  ```

* **“No compatible ingest function found in src.services.ingest”**
  Your index is not in `items / manifests / entries` format **or** Hub failed to fetch JSON (got HTML error page).
  **Fix**:

  ```bash
  rm -f matrix/index.json
  python3 scripts/init.py init-empty --shape items
  python3 scripts/init.py add-url --manifest-url "http://127.0.0.1:8001/matrix/hello-server.manifest.json"
  curl -sS http://127.0.0.1:8001/matrix/index.json | jq .   # MUST be JSON with "items":[{"manifest_url":...}]
  ```

* **422 on `/catalog/install`**
  Include `"id": "mcp_server:<name>@<version>"` in the JSON body even when sending inline `manifest`.

* **500 on `/catalog/install`**
  Usually means the entity isn’t in DB (when you do UID-only install) or env misconfig.

  * If you do UID-only install: first ensure **ingest** succeeded.
  * For inline install: check DB schema exists (`INIT_DB=true` in .env or `make upgrade`), and Gateway env (`MCP_GATEWAY_URL`, `MCP_GATEWAY_TOKEN`).

* **Server not reachable (registration fails)**
  Make sure the URL in your manifest (`mcp_registration.server.url`) is reachable **from the Hub/Gateway process** (Docker networking matters!).

---

## 8) When Hub is online (e.g., `https://www.matrixhub.io`)

* Use:

  ```bash
  export HUB_URL="https://www.matrixhub.io"
  ```
* Publish your `matrix/index.json` and manifests on public HTTP URLs.
* Run the same `/remotes` → `/ingest` → `/catalog/install` with those public URLs.

---

## 9) TL;DR (copy-paste)

### **Start Hub & set token**

```bash
make dev
make gateway-token

# paste the two export lines printed by make gateway-token:
export ADMIN_TOKEN='...'
export HUB_ENDPOINT='0.0.0.0:7300'

# Normalize HUB_URL for curl
if [[ "$HUB_ENDPOINT" == 0.0.0.0:* ]]; then
  export HUB_URL="http://127.0.0.1:${HUB_ENDPOINT##*:}"
else
  export HUB_URL="http://${HUB_ENDPOINT}"
fi
echo "$HUB_URL"   # http://127.0.0.1:7300
```

### **Catalog (local)**

```bash
# Serve your content
python3 -m http.server 8001

# Create supported index & add your manifest
rm -f matrix/index.json
python3 scripts/init.py init-empty --shape items
python3 scripts/init.py add-url --manifest-url "http://127.0.0.1:8001/matrix/hello-server.manifest.json"

# Register & ingest
export INDEX_URL="http://127.0.0.1:8001/matrix/index.json"
curl -sS -X POST "$HUB_URL/remotes" -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" -d "{\"url\":\"$INDEX_URL\"}" | jq .
curl -sS -X POST "$HUB_URL/ingest" -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" -d "{\"url\":\"$INDEX_URL\"}" | jq .

# Install (register into MCP-Gateway)
curl -sS -X POST "$HUB_URL/catalog/install" -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" -d '{"id":"mcp_server:hello-sse-server@0.1.0","target":"./"}' | jq .
```

### **Direct install**

```bash
curl -sS -X POST "$HUB_URL/catalog/install" -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" -d @- <<'JSON'
{
  "id": "mcp_server:hello-sse-server@0.1.0",
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
        "url": "http://127.0.0.1:8000/messages/"
      }
    }
  }
}
JSON
```

---

With these steps — **supported index shape** (`items`), **HTTP served files** (or public URLs), **correct HUB\_URL/token**, and **inline manifest for direct install** — you will avoid:

* *“URL using bad/illegal format or missing URL”*
* *“No compatible ingest function found in src.services.ingest”*
* *422 (“id field required”) on direct install*

…and have a reliable workflow to ingest and install locally today — and then seamlessly move to **[https://www.matrixhub.io](https://www.matrixhub.io)** tomorrow.
