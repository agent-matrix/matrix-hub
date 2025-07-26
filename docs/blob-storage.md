# Blob Storage

Stores long text artifacts (READMEs, examples) for retrieval-augmented generation (RAG).

## Backends

- **Local disk** (default): `${BLOB_DIR:-./data/blobs}`
- **Object storage (later)**: S3/MinIO with lifecycle policies

## Keys & Paths

- Key format: `"{entity_uid}/{section}/{position}"` → sanitized to a flat path
- Files are UTF-8 text
- Checksums stored in DB to detect changes

## Retention

- Keep last N versions per entity (configurable).
- GC job prunes orphan blobs after successful re-indexing.

## Security

- No secrets in blob content.
- If private catalogs are used, ensure the object store is private and accessed via presigned URLs.
