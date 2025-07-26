# Ingestors

The ingestor discovers manifests from remote catalogs and feeds the validator + normalizer.

## Sources

- **Mode A — index.json** (preferred): a single file listing manifest URLs (and optional checksums).
- **Mode B — tree/ZIP**: list repo trees via API or download a ZIP and scan `*.manifest.yaml`.

### Sample `index.json`

```json
{
  "manifests": [
    "[https://raw.githubusercontent.com/agent-matrix/catalog/main/agents/pdf-summarizer/1.4.2/agent.manifest.yaml](https://raw.githubusercontent.com/agent-matrix/catalog/main/agents/pdf-summarizer/1.4.2/agent.manifest.yaml)",
    "[https://raw.githubusercontent.com/agent-matrix/catalog/main/tools/ocr/0.3.1/tool.manifest.yaml](https://raw.githubusercontent.com/agent-matrix/catalog/main/tools/ocr/0.3.1/tool.manifest.yaml)"
  ],
  "commit": "abc123",
  "generated_at": "2025-07-10T12:30:00Z"
}
```

### Scheduling
Default: every 15 minutes via APScheduler (`INGEST_INTERVAL_MIN`).
Manual trigger: `POST /catalog/ingest?remote=name` (if admin token enabled).

### HTTP Etiquette
Use `ETag`/`Last-Modified` to avoid re-downloading.
Respect `429`/`5xx` with exponential backoff.
Timeouts tuned (connect/read) to keep the scheduler responsive.

### Provenance & Idempotency
Each upsert stores `remote.name`, `commit/etag`, and `last_sync_ts`.
Upsert key: `(type, id, version)`; replays are safe.
On validation failure: entity is rejected with reason (stored for debugging).
