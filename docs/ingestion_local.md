# Matrix Hub — Quick Start (Local Ingest & Install)

This is the **definitive, step-by-step** guide to add MCP servers/tools/agents to **Matrix-Hub** on your local machine.
No prior knowledge is required — we explain every step and show **copy-paste ready** commands.

You’ll learn **two ways** to get content into Matrix-Hub:

* **A) Catalog flow (recommended for scale)**
  You publish an `index.json` (and your manifests) over **HTTP**. The Hub **downloads** that URL, parses it, writes entities into the **database**, and then you “install” (register into the **MCP-Gateway**).

* **B) Direct install (quick local test)**
  You call `/catalog/install` with an ID (and optionally an inline manifest), skipping catalog/ingest.

> ### Why do I need `python3 -m http.server 8001`?
>
> Matrix-Hub must **download** your `matrix/index.json` and manifests via **HTTP** — it can’t read local files directly.
> For local dev, the easiest way is:
>
> ```bash
> python3 -m http.server 8001
> ```
>
> This serves your repo over HTTP at `http://127.0.0.1:8001/`.
> If your files are already published (GitHub raw, S3/CDN), **you don’t need** this local server.

---

## 0) Start Matrix-Hub locally

From the **Matrix-Hub repo root**:

```bash
# One-time:
make setup

# Start the API server (port 443)
make dev
```

Verify it’s alive:

```bash
curl -sS http://127.0.0.1:443/health
# expect 200 OK with a JSON body
```

> **.env note**: If you use `.env`, it’s loaded by `make dev`.
> **Auth note**: For protected endpoints, set `API_TOKEN=<token>` in `.env` and pass `-H "Authorization: Bearer <token>"` in `curl` calls.

---

## 1) Get an admin token & set `HUB_URL` (the **right** way)

Use the helper to get an admin token and endpoint:

```bash
make gateway-token
```

It prints something like:

```
### Generating MCP Gateway Admin Token & Hub Endpoint ###
⏳ Minting admin JWT for user 'admin'...
✅ Token and endpoint prepared. Use 'eval' to export them.
export ADMIN_TOKEN='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...'
export HUB_ENDPOINT='0.0.0.0:443'
```

Now **export** those values (copy/paste exactly):

```bash
export ADMIN_TOKEN='ey...<snip>...'
export HUB_ENDPOINT='0.0.0.0:443'
```

Normalize `HUB_URL` for curl:

```bash
# If HUB_ENDPOINT is "0.0.0.0:443", convert it to "http://127.0.0.1:443"
if [[ "$HUB_ENDPOINT" == 0.0.0.0:* ]]; then
  export HUB_URL="http://127.0.0.1:${HUB_ENDPOINT##*:}"
else
  export HUB_URL="http://${HUB_ENDPOINT}"
fi

echo "HUB_URL=$HUB_URL"
# -> HUB_URL=http://127.0.0.1:443
```

> **Why not 0.0.0.0?** That’s a **bind** address on the server. Clients should use `127.0.0.1:443` (or your LAN IP/hostname).

---

## 2) Choose a flow

### Option A — Catalog flow (recommended for scale)

You **host**:

```
<project>/
└─ matrix/
   ├─ index.json                  # your catalog (Hub downloads this)
   └─ hello-server.manifest.json  # example server manifest
```

Matrix-Hub **fetches** your `index.json`, parses it, then fetches each `manifest_url` and writes **Entity** rows into the Hub DB.

> For **local dev**, host `matrix/` via:
>
> ```bash
> python3 -m http.server 8001
> ```
>
> Your **index** will be at: `http://127.0.0.1:8001/matrix/index.json`

### Option B — Direct install (quick test)

You skip `index.json` and ingestion. You call `/catalog/install` with:

* `"id": "mcp_server:your-id@version"`
* Optionally with an inline `"manifest": {...}`

This is great for quick tests and avoids needing DB or ingestion.

---

## 3A) Catalog flow — Create a correct index & serve it

> The ingestor supports **one** of these top-level keys in `index.json`:
>
> * **Form A**: `"manifests"`
>   `{"manifests": ["https://.../x.manifest.json", ...]}`
>
> * **Form B**: `"items"`
>   `{"items": [{"manifest_url": "https://.../x.manifest.json"}, ...]}`
>
> * **Form C**: `"entries"`
>   `{"entries": [{"path":"x.manifest.json","base_url":"https://host/matrix/"}]}`
>
> If you use `entities` or something else, you will see:
> **“No compatible ingest function found in src.services.ingest”.**

### 3A.1) Create **supported** index shape: `items`

From the Matrix-Hub repo root:

```bash
rm -f matrix/index.json
python3 scripts/init.py init-empty --shape items
```

### 3A.2) Add your manifest URL to the index

```bash
python3 scripts/init.py add-url \
  --manifest-url "http://127.0.0.1:8001/matrix/hello-server.manifest.json"
# (We’ll start the web server in a moment.)
```

This produces `matrix/index.json` like:

```json
{
  "items": [
    { "manifest_url": "http://127.0.0.1:8001/matrix/hello-server.manifest.json" }
  ],
  "meta": { "format": "matrix-hub-index", "version": 1, "...": "..." }
}
```

### 3A.3) Serve your repo folder

In the **same repo root** (the folder containing your `matrix/` directory):

```bash
python3 -m http.server 8001
```

Open a **new terminal**, and check your files are reachable:

```bash
# Verify this returns JSON with "items"[...]
curl -sS http://127.0.0.1:8001/matrix/index.json | jq .

# Verify your manifest is reachable:
curl -sS http://127.0.0.1:8001/matrix/hello-server.manifest.json | jq .
```

Export your index URL:

```bash
export INDEX_URL="http://127.0.0.1:8001/matrix/index.json"
```

> **Critical sanity check**: If the JSON printed by `curl` does **not** show `"items"` or shows unexpected URLs, you are **serving the wrong folder** — cd to the folder that contains your `matrix/` and run `python3 -m http.server 8001` **there**.

---

## 4A) Register your index & ingest

Make sure `HUB_URL` and `ADMIN_TOKEN` are set (Step 1).

### 4A.1) Register the remote

```bash
curl -sS -X POST "$HUB_URL/remotes" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"url\":\"$INDEX_URL\"}" | jq .
```

You should see an idempotent response like:

```json
{ "added": true, "url": "http://127.0.0.1:8001/matrix/index.json", "total": 1 }
```

If you get `URL using bad/illegal format or missing URL`, your `$HUB_URL` is empty. Go back to **Step 1** and export it correctly.

### 4A.2) Ingest

```bash
curl -sS -X POST "$HUB_URL/ingest" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"url\":\"$INDEX_URL\"}" | jq .
```

Expected outcome:

* `"ok": true` for your index, with stats (manifests processed)
* Your Entity row (`mcp_server:hello-sse-server@0.1.0`) upserted in the DB

> **If you see** `No compatible ingest function found`:
>
> * Your index shape is wrong or
> * Hub fetched a non-JSON page (like HTML error)
>
> **Fix**:
>
> ```bash
> rm -f matrix/index.json
> python3 scripts/init.py init-empty --shape items
> python3 scripts/init.py add-url --manifest-url "http://127.0.0.1:8001/matrix/hello-server.manifest.json"
> curl -sS http://127.0.0.1:8001/matrix/index.json | jq .  # MUST be JSON with "items":[{"manifest_url": "..."}]
> ```
>
> Then run `/remotes` and `/ingest` again.

---

## 4A.3) Install (register into MCP-Gateway)

Now that the Entity exists in the DB from ingest, install by UID:

```bash
curl -sS -X POST "$HUB_URL/catalog/install" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"id":"mcp_server:hello-sse-server@0.1.0","target":"./"}' | jq .
```

This reads the manifest via the Entity’s `source_url` and, if it has:

```json
"mcp_registration": {
  "server": {
    "name": "hello-sse-server",
    "transport": "SSE",
    "url": "http://127.0.0.1:8000/messages/"
  }
}
```

…it will call MCP-Gateway to **register** that server.

> **Gateway env**: In your Hub `.env`, set:
>
> ```
> MCP_GATEWAY_URL=http://127.0.0.1:4444
> MCP_GATEWAY_TOKEN=supersecret
> ```
>
> Restart the Hub after setting env. Without these, registration will fail (401). Check Hub logs (`make dev` terminal) for details.

---

## 3B) Direct install (skip catalog/ingest)

For quick testing (no index required), send the **inline manifest**:

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

> If you still get **500** on direct install:
>
> * Make sure the DB schema exists (for SQLite dev: `INIT_DB=true` in `.env` or run `make upgrade`).
> * Ensure `MCP_GATEWAY_URL` and `MCP_GATEWAY_TOKEN` are set **in the Hub process** (restart after changing).
> * Check the logs from the terminal where `make dev` is running — tracebacks point to the exact cause.

---

## 5) Make sure your MCP server is reachable

If your manifest specifies `"url": "http://127.0.0.1:8000/messages/"`, **run the server**:

```bash
uvicorn agents.hello_world.server_sse:app --host 127.0.0.1 --port 8000
# It exposes SSE/POST on /messages/
```

> **Docker note**: If Hub or Gateway runs in Docker, `127.0.0.1` refers to the container. Use `http://host.docker.internal:8000/` (Docker Desktop) or a LAN IP/compose service DNS so the container can reach your server.

---

## 6) Quick connectivity test (optional helper)

You can validate **Hub health** and **index/manifest reachability & shape** with:

```bash
scripts/test_remote_connection.sh \
  --index "http://127.0.0.1:8001/matrix/index.json" \
  --manifest "http://127.0.0.1:8001/matrix/hello-server.manifest.json"
```

If it shows 200 for both and recognizes the index shape (`items`, `manifests`, or `entries`), `/ingest` will work.

---

## 7) Common pitfalls (and precise fixes)

* **“URL using bad/illegal format or missing URL”**
  You didn’t set `HUB_URL`. Do **Step 1** (`make gateway-token`), export `ADMIN_TOKEN` & `HUB_ENDPOINT`, then normalize `HUB_URL`.
  Sanity check:

  ```bash
  echo "$HUB_URL"   # should be http://127.0.0.1:443
  ```

* **“No compatible ingest function found in src.services.ingest”**
  Your `index.json` is not in `items/manifests/entries` form **or** Hub fetched a non-JSON page.
  Fix:

  ```bash
  rm -f matrix/index.json
  python3 scripts/init.py init-empty --shape items
  python3 scripts/init.py add-url --manifest-url "http://127.0.0.1:8001/matrix/hello-server.manifest.json"
  curl -sS http://127.0.0.1:8001/matrix/index.json | jq .  # Must show "items":[{"manifest_url":"..."}]
  ```

  And ensure you're serving the correct folder with `python3 -m http.server 8001` in that directory.

* **422 on `/catalog/install`**
  Your API expects `"id"` in the body. Include `"id": "mcp_server:<name>@<version>"` even when sending inline `manifest`.

* **500 on `/catalog/install`**
  Usually happens if:

  * The Entity isn’t in DB (when doing UID-only install) → fix by ingesting first.
  * Gateway env isn’t set or reachable (`MCP_GATEWAY_URL`, `MCP_GATEWAY_TOKEN`).
  * DB schema not initialized (SQLite dev: `INIT_DB=true` or run `make upgrade`).

* **Serving the wrong folder**
  You must run `python3 -m http.server 8001` **in the same directory** that contains your `matrix/` folder and the `index.json` you created. Recheck with:

  ```bash
  curl -sS http://127.0.0.1:8001/matrix/index.json | jq .
  ```

---

## 8) When Hub is online (e.g., `https://www.matrixhub.io`)

* Set:

  ```bash
  export HUB_URL="https://www.matrixhub.io"
  ```
* Publish your `matrix/index.json` and manifests on public URLs (GitHub raw, S3).
* Run the same `/remotes` → `/ingest` → `/catalog/install` flow with those public URLs.

---

## 9) TL;DR (copy-paste)

### Start Hub & set token

```bash
make dev
make gateway-token

# paste the two export lines:
export ADMIN_TOKEN='...'
export HUB_ENDPOINT='0.0.0.0:443'

# normalize HUB_URL:
if [[ "$HUB_ENDPOINT" == 0.0.0.0:* ]]; then
  export HUB_URL="http://127.0.0.1:${HUB_ENDPOINT##*:}"
else
  export HUB_URL="http://${HUB_ENDPOINT}"
fi
echo "$HUB_URL"  # http://127.0.0.1:443
```

### Catalog (local)

```bash
# Serve your repo folder (must contain /matrix)
python3 -m http.server 8001

# Create supported index shape & add manifest
rm -f matrix/index.json
python3 scripts/init.py init-empty --shape items
python3 scripts/init.py add-url --manifest-url "http://127.0.0.1:8001/matrix/hello-server.manifest.json"

# sanity test (should show "items":[{"manifest_url":"..."}])
curl -sS http://127.0.0.1:8001/matrix/index.json | jq .

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

### Direct install

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

## Quick reality checks

* **Is my index served?**
  `curl -sS http://127.0.0.1:8001/matrix/index.json | jq .`
  *Must show proper JSON with `"items":[{"manifest_url":"..."}]`.*

* **Is my Hub URL set?**
  `echo "$HUB_URL"` → *must be `http://127.0.0.1:443`.*

* **Do I have logs?**
  The terminal running `make dev` shows detailed errors if something fails (DB, Gateway registration, schema mismatch, etc.).

---

With these steps — **supported index** (`items`), **correctly served folder**, **HUB\_URL + ADMIN\_TOKEN set**, **DB initialized**, and **inline manifest** available when needed — you will reliably ingest and install locally. Later, switch to public URLs and `https://www.matrixhub.io` with the **same workflow**.
