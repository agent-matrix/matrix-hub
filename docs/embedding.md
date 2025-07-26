# Embedding

Encodes chunks into vectors for semantic search & hybrid ranking.

## Embedder

- Default: lightweight sentence transformer (config: `EMBED_MODEL`).
- Batch size & concurrency tuned to avoid memory spikes.

## Failure & Retries

- If the model fails, the chunk is marked **pending**; the scheduler retries later.
- We never block ingestion of the catalog on embedding failures.

## Stored Fields

- `entity_uid`
- `chunk_id`
- `vector` (list of floats / DB-specific binary)
- `dim`, `model_id`, `created_at`

## Replacement Policy

- Re-embedding occurs only when:
  - Chunk text or weight changed, or
  - Embedder `model_id` changed, or
  - Admin forced re-embed.
