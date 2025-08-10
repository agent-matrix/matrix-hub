# API — Endpoints

Base URL defaults to `http://localhost:7300`.

---

## `GET /health`

**Query params**

* `check_db` (bool, optional): also checks DB connectivity.

**Response**

```json
{ "status": "ok", "db": "ok" }
```

---

## `GET /catalog/search`

Hybrid search with filters.
Now also used by the `scripts/list_ingested.sh` helper to list **all ingested items**.

**Params**

* `q` (optional): text query
* `type`: `agent` | `tool` | `mcp_server`
* `capabilities`, `frameworks`, `providers` (CSV)
* `mode`: `keyword` | `semantic` | `hybrid`
* `limit`: default `20`
* `with_rag`: `true` to include a short fit explanation

**200 Response (truncated)**

```json
{
  "items": [
    {
      "id": "agent:pdf-summarizer@1.4.2",
      "type": "agent",
      "name": "PDF Summarizer",
      "version": "1.4.2",
      "summary": "...",
      "capabilities": ["pdf", "summarize"],
      "frameworks": ["langgraph"],
      "providers": ["watsonx"],
      "score_lexical": 0.8,
      "score_semantic": 0.7,
      "score_final": 0.79,
      "fit_reason": "Matches 'summarize pdfs'..."
    }
  ],
  "total": 1
}
```

**Verification via script**

```bash
# Lists all ingested entities as a table
scripts/list_ingested.sh

# Only show MCP servers
TYPE=mcp_server scripts/list_ingested.sh

# Raw JSON
FORMAT=json scripts/list_ingested.sh
```

---

## `GET /catalog/entities/{id}`

Return full metadata for an entity (resolved from the ingested manifests).

**Example**

```
GET /catalog/entities/agent:pdf-summarizer@1.4.2
```

---

## `POST /catalog/install`

Execute an install plan (also performs MCP Gateway registration if `mcp_registration` is present in the manifest).

**Body**

```json
{
  "id": "agent:pdf-summarizer@1.4.2",
  "target": "./apps/pdf-bot",
  "manifest": { ... } // optional if already ingested
}
```

**Notes:**

* `id` must be in the format `<type>:<id>@<version>` matching the manifest.
* `target` is the directory where artifacts, adapters, and `matrix.lock.json` will be written.
* If `manifest` is included inline, ingestion into the catalog is **not** required beforehand.

**200 Response (truncated)**

```json
{
  "plan": { "artifacts": [...], "adapters": [...], "mcp_registration": {...} },
  "results": [
    {"step":"pypi","ok":true,"elapsed_secs":5.9},
    {"step":"adapters.write","ok":true,"extra":{"count":1}},
    {"step":"gateway.register","ok":true,"extra":{"tool":{"id":"..."}}}
  ],
  "files_written": [
    "apps/pdf-bot/src/flows/pdf_summarizer_node.py",
    "apps/pdf-bot/matrix.lock.json"
  ],
  "lockfile": { "version": 1, "entities": [ ... ] }
}
```

---

## `GET /catalog/remotes`

## `POST /catalog/remotes`

List or add remote catalogs (`index.json` URLs).
Admin-only if `API_TOKEN` is set.

---

## `POST /catalog/ingest?remote=<name>`

Manually trigger ingestion for a configured remote.
Admin-only if `API_TOKEN` is set.

---

## Optional: `GET /gateway/{kind}`

Convenience read-only view into the MCP Gateway registrations (if enabled in your build).

