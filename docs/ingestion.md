# Ingestion

Matrix Hub ingests manifests from one or more remotes and stores normalized metadata in the catalog DB.

## Sources

- **index.json** files published by your catalog (e.g., GitHub Pages or raw Git URLs).
- Each index entry points at a `*.manifest.yaml` (agent, tool, or mcp-server).

## Validation

- Manifests are validated against JSON Schemas:
  - `schemas/agent.manifest.schema.json`
  - `schemas/tool.manifest.schema.json`
  - `schemas/mcp-server.manifest.schema.json`

Invalid manifests are **skipped** and logged.

## Scheduling

- Background job polls remotes every `INGEST_INTERVAL_MIN` minutes (default 15).
- Manual trigger via `POST /catalog/ingest?remote=<name>` (admin).

## Provenance

- The DB stores the manifest URL and optional commit/hash, enabling traceability.
