# Vector Indexing

Matrix Hub supports a pluggable vector layer:

- **Day-1**: `pgvector` (PostgreSQL extension)
- **Later**: Milvus/FAISS/Weaviate (adapter interface is already isolated)

## pgvector (recommended to start)

- Table: `embedding_chunk`
  - `entity_uid`, `chunk_id`, `vector`, `weight`, `model_id`, timestamps
- Index type: IVF/Flat/HNSW (choose based on your pgvector version and dataset size)
- Tunables:
  - IVF lists / probes for recall vs. latency
  - HNSW `m`, `ef_search` if available
- Filter strategy: apply filters on `entity` first (type, caps), then join candidates to ANN results.

### Example (conceptual)

```sql
-- Create extension (once)
CREATE EXTENSION IF NOT EXISTS vector;

-- Example index (IVF, dimensionality N)
-- CREATE INDEX ON embedding_chunk USING ivfflat (vector vector_l2_ops) WITH (lists=100);
```

## Alternatives (future)
Milvus: stand-alone ANN with collections per `model_id`.
API contracts for vector search remain the same: `search(query_vec, filters, k) → hits`.
