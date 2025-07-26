# Search

Matrix Hub supports **lexical**, **semantic**, and **hybrid** ranking.

## Lexical (keyword)

- Backend: **pg_trgm** (PostgreSQL trigram), using BM25-ish scoring.
- Fields: name, summary, description, tags/capabilities (flattened).

## Semantic (vector)

- Backend: **pgvector** (optional).
- Embedding: pluggable; the default build exposes a dummy embedder for local trials.

## Hybrid ranking

Score is a weighted blend:
`score_final = w_sem * semantic + w_lex * lexical + w_q * quality + w_r * recency`


Weights are configurable via `SEARCH_HYBRID_WEIGHTS` (e.g., `sem:0.6,lex:0.4,rec:0.1,q:0.1`).

## RAG fit reasoning (optional)

When `with_rag=true`, the service can fetch top README/manifest chunks and produce a short “fit_reason” string for each hit.

## Limits

- On SQLite, only **keyword** mode is available.
- For large scale, consider migrating to **Milvus/Weaviate** for ANN and **OpenSearch** for lexical, keeping the same public API.
