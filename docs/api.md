# API — Endpoints

Base URL defaults to `http://localhost:443`.

This Hub stores a catalog of manifests (agents/tools/mcp\_servers), installs artifacts, and syncs MCP servers into **MCP-Gateway**. Mutating endpoints require an admin token if `API_TOKEN` is set.

---

## Auth

When `API_TOKEN` is configured in the Hub:

```
Authorization: Bearer <API_TOKEN>
```

Admin-only endpoints below are marked accordingly.

---

## `GET /health`

Check service health.

**Query params**

* `check_db` (bool, optional): also checks DB connectivity.

**200 Response**

```json
{ "status": "ok", "db": "ok" }
```

---

## `GET /catalog/search`

Hybrid search with filters (keyword/semantic/hybrid). Also handy for listing ingested items.

**Query params**

* `q` (string, optional): text query
* `type` (string, optional): `agent` | `tool` | `mcp_server`
* `capabilities` (CSV, optional)
* `frameworks` (CSV, optional)
* `providers` (CSV, optional)
* `mode` (string, optional): `keyword` | `semantic` | `hybrid` (default: `hybrid`)
* `limit` (int, default: `20`)
* `with_rag` (bool, optional): include a brief fit explanation

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

**Useful scripts**

```bash
# Lists all ingested entities as a table from the DB (falls back to API)
scripts/list_ingested.sh

# JSON output only
FORMAT=json scripts/list_ingested.sh

# Only MCP servers
TYPE=mcp_server scripts/list_ingested.sh
```

---

## `GET /catalog/entities/{id}`

Return full metadata for an entity (resolved from the ingested manifests).

**Example**

```
GET /catalog/entities/agent:pdf-summarizer@1.4.2
```

**404** if not found.

---

## `POST /catalog/install`  *(admin)*

Execute an install plan (artifacts/adapters) and best-effort **MCP-Gateway** registration when `mcp_registration` is present.

**Body**

```json
{
  "id": "mcp_server:hello-sse-server@0.1.0",
  "target": "./apps/hello",
  "manifest": { ... }               // optional; if provided, it will be saved to DB
}
```

**Notes**

* `id` must be `<type>:<slug>@<version>` and match the manifest.
* If `manifest` is provided inline:

  * It is persisted as a catalog `Entity`.
  * `mcp_registration` is saved on the entity (used later by sync).
  * A `matrix.lock.json` is written under `target`.
* Best-effort gateway registration is attempted; errors are recorded in results and `entity.gateway_error`.

**200 Response (truncated)**

```json
{
  "plan": { "artifacts": [...], "adapters": [...], "mcp_registration": {...} },
  "results": [
    {"step":"git.checkout","ok":true,"elapsed_secs":1.12},
    {"step":"adapters.write","ok":true,"extra":{"skipped":true}},
    {"step":"gateway.register","ok":true,"extra":{}},
    {"step":"lockfile.write","ok":true,"extra":{"path":"/path/to/matrix.lock.json"}}
  ],
  "files_written": ["matrix.lock.json"],
  "lockfile": { "version": 1, "entities": [ ... ] }
}
```

---

## Remotes (catalog sources)

These endpoints manage remote catalog indexes (each is an `index.json` URL). When no remotes are stored, the Hub seeds them from `MATRIX_REMOTES` (CSV or JSON array) the first time you call `GET /remotes` or `POST /remotes/sync`.

### `GET /remotes`

List configured remotes. If DB is empty, this call seeds from `MATRIX_REMOTES`.

**200 Response**

```json
{
  "items": [{"url":"https://raw.githubusercontent.com/agent-matrix/catalog/main/index.json"}],
  "count": 1
}
```

### `POST /remotes`  *(admin)*

Add a remote index URL.

**Body**

```json
{ "url": "https://example.com/catalog/index.json" }
```

**201 Response**

```json
{ "added": true, "url":"https://example.com/catalog/index.json", "total": 3 }
```

### `DELETE /remotes`  *(admin)*

Remove a remote index URL.

**Body**

```json
{ "url": "https://example.com/catalog/index.json" }
```

**200 Response**

```json
{ "removed": true, "url":"https://example.com/catalog/index.json", "total": 2 }
```

---

## Ingest & Sync

### `POST /ingest`  *(admin)*

Manually trigger ingestion for one or all remotes.

**Body**

```json
{ "url": "https://raw.githubusercontent.com/agent-matrix/catalog/main/index.json" }
// or omit "url" to ingest all remotes
```

**200 Response (truncated)**

```json
{
  "results": [
    { "url": "https://.../index.json", "ok": true, "stats": { "...": "..." } }
  ]
}
```

### `POST /remotes/sync`  *(admin)*

End-to-end sync:

1. Ensure remotes exist (seed from `MATRIX_REMOTES` if empty).
2. Ingest each remote.
3. Register **new** MCP servers into MCP-Gateway (Tool → Resources → Prompts → Gateway).

**200 Response**

```json
{
  "seeded": false,
  "ingested": ["https://raw.githubusercontent.com/agent-matrix/catalog/main/index.json"],
  "errors": { "https://bad.example/index.json": "HTTP 404 ..." },
  "synced": true,
  "count": 1
}
```

---

## Gateways (pending → registered)

These endpoints help you see what’s ingested but **not yet** registered in MCP-Gateway, and clean them up if needed.

### `GET /gateways/pending`  *(admin)*

List ingested MCP servers with `gateway_registered_at IS NULL`.

**Query params**

* `limit` (int, default: `100`, max `1000`)
* `offset` (int, default: `0`)

**200 Response**

```json
{
  "items": [
    {
      "uid": "mcp_server:watsonx-agent@0.1.0",
      "name": "Watsonx Chat Agent",
      "version": "0.1.0",
      "source_url": null,
      "has_registration": true,
      "server_url": "http://127.0.0.1:6288/sse",
      "transport": "SSE",
      "gateway_error": "Resource response missing numeric 'id'"
    }
  ],
  "count": 1
}
```

**Tip:** This is exactly what `scripts/list_pending_gateways.sh` displays.

### `DELETE /gateways/pending/{uid}`  *(admin)*

Delete a **pending** `mcp_server` by UID (does nothing if it’s already registered).

**200 Response**

```json
{ "removed": true, "uid": "mcp_server:code@0.1.0" }
```

**404** is not used; if the row can’t be deleted you get:

```json
{ "removed": false, "uid": "mcp_server:code@0.1.0", "reason": "not found|not an mcp_server|already registered" }
```

### `POST /gateways/pending/delete`  *(admin)*

Bulk delete pending MCP servers.

**Body**

```json
{
  "uids": ["mcp_server:watsonx-agent@0.1.0", "mcp_server:code@0.1.0"],
  "all": false,
  "error_only": false
}
```

* Provide either `uids` **or** set `all=true`.
* With `error_only=true`, only entities with `gateway_error` are deleted.

**200 Response**

```json
{
  "removed": ["mcp_server:code@0.1.0"],
  "skipped": { "mcp_server:watsonx-agent@0.1.0": "already registered" },
  "total_removed": 1
}
```

---

## Scripts (helpers)

* `scripts/list_ingested.sh`
  Lists all ingested `mcp_server` rows from the DB (falls back to `/gateways/pending` if DB is unavailable). Shows status: `PENDING` vs `REGISTERED`.

* `scripts/list_pending_gateways.sh`
  Calls `GET /gateways/pending` and prints a table. Exits with non-zero if any pending exist (useful in CI).

* `scripts/verify_token.sh`
  Verifies your Hub → Gateway auth and lists `/servers` and `/gateways` on MCP-Gateway.

* `examples/register_watsonx_local_via_hub.sh`
  Pushes an inline `mcp_server` manifest to the Hub and triggers `/remotes/sync` (which registers the server into MCP-Gateway).

---

## Behavior notes

* **Inline install parity**: an inline `manifest` in `POST /catalog/install` is now persisted in the DB, including `mcp_registration`. The same fields drive `/remotes/sync`.
* **Gateway registration flow** (on sync):
  `Tool → Resources → Prompts → Gateway`. SSE endpoints are normalized to `/messages/` when appropriate.
* **Error visibility**: sync errors are recorded in `entity.gateway_error` and surfaced by `GET /gateways/pending`.

---

## Optional: Gateway pass-throughs

If you run the Gateway locally, use the Gateway’s own API (auth header from `scripts/verify_token.sh`):

* `GET /health`
* `GET /servers`
* `GET /gateways`
* `POST /gateways` (register a federated server)

> These are **not** Hub endpoints; they belong to MCP-Gateway.

---

## Status codes

* `200`  OK
* `201`  Created (`POST /remotes`)
* `400`  Bad request (invalid body or params)
* `401`  Unauthorized (missing/invalid token when required)
* `404`  Not found (for entity lookups; delete-pending returns a soft reason instead)
* `409`  Conflict (idempotent creates may translate to OK upstream)
* `500`  Internal server error

---

## Environment

* `API_TOKEN` — enables admin protection on mutating routes.
* `MATRIX_REMOTES` — CSV or JSON array of index URLs; used to seed remotes when empty.
* `DATA_DIR` / `DB_PATH` — where `catalog.sqlite` is stored (deployment-specific).
* Gateway auth used by the Hub (for sync): `MCP_GATEWAY_URL`, `JWT_SECRET_KEY`, `BASIC_AUTH_USERNAME`, `MCP_GATEWAY_TOKEN`.

---
