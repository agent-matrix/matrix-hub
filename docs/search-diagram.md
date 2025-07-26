## Search & Indexing Architecture

The diagram below shows the “Ingest & Index Pluggable” → “Query & Rank Stable API” flow, and the table that follows maps each piece to the `matrix-hub` modules that implement it (as well as the native client and SDK).

```mermaid
flowchart LR
    subgraph Ingest & Index Pluggable
        G[GitHub Ingestor\nmanifests + READMEs] --> N[Normalizer\nvalidate + enrich + version]
        N --> D[Catalog DB\nPostgres]
        N --> C[Chunker\nname/desc/README/examples]
        C --> E[Embedder\nmodel: MiniLM/*; Workers: in-process or Celery]
        E --> V[Vector Index\npgvector ⟶ Milvus later]
        N --> B[BlobStore\nlocal disk ⟶ S3/MinIO later]
    end

    subgraph Query & Rank Stable API
        U[User query + filters] --> S[/GET /catalog/search/]
        S --> L[Lexical\npg_trgm BM25 ⟶ OpenSearch later]
        S --> Q[Vector ANN\npgvector ⟶ Milvus later]
        D --> L
        V --> Q
        L --> H[Hybrid Ranker\nweights in config]
        Q --> H
        H -->|top‑K| R[RAG optional\nfetch best chunks from BlobStore + summarize fit]
        R --> O[JSON response: items + scores + fit_reason]
        H --> O
    end
````

### Implementation Mapping

| Flow Node                                              | Package / Module                 | File(s)                                              |
| ------------------------------------------------------ | -------------------------------- | ---------------------------------------------------- |
| **GitHub Ingestor**<br/>(manifests + READMEs)          | `matrix-hub` (Companion service) | `src/services/ingest.py`                             |
| **Normalizer**<br/>(validate + enrich + version)       | `matrix-hub`                     | `src/services/validate.py` + parts of `ingest.py`    |
| **Catalog DB**<br/>(Postgres or SQLite)                | `matrix-hub`                     | `src/db.py`, `src/models.py`                         |
| **Chunker**<br/>(name/desc/README/examples)            | `matrix-hub` (search internals)  | `src/services/search/chunking.py`                    |
| **Embedder**<br/>(MiniLM model; workers)               | `matrix-hub` (search backends)   | `src/services/search/backends/embedder.py`           |
| **Vector Index**<br/>(pgvector → Milvus)               | `matrix-hub` (search backends)   | `src/services/search/backends/vector.py`             |
| **BlobStore**<br/>(local disk → S3/MinIO)              | `matrix-hub` (search backends)   | `src/services/search/backends/blobstore.py`          |
| **GET /catalog/search**<br/>(Stable API)               | `matrix-hub` (API routes)        | `src/routes/catalog.py`                              |
| **Lexical Search**<br/>(pg\_trgm BM25 → OpenSearch)    | `matrix-hub` (search backends)   | `src/services/search/backends/lexical.py`            |
| **Hybrid Ranker**<br/>(weights in config)              | `matrix-hub` (search logic)      | `src/services/search/ranker.py`                      |
| **RAG (optional)**<br/>(fetch best chunks + summarize) | `matrix-hub` (search logic)      | `src/services/search/rag.py`                         |
| **Python SDK**<br/>(client library)                    | `matrix-python-sdk`              | `matrix_sdk/client.py`, `cache.py`, `types.py`       |
| **Agent Creator**<br/>(native CLI client)              | `matrix-cli`                     | `matrix_cli/__main__.py`, `matrix_cli/commands/*.py` |
| **Agent Generator Plugin**<br/>(reuse‑first)           | `agent-generator-matrix`         | `agent_generator_matrix/plugin.py`                   |

> **Note:**
> • All ingestion, indexing, embedding and search‑and‑rank logic lives in **`matrix-hub`** under its `services/` and `routes/` directories.
> • The **Python SDK** (`matrix-python-sdk`) and **CLI** (`matrix-cli` aka “agent‑creator”) are the native clients of the platform.
> • The **`agent-generator-matrix`** plugin hooks your `planning_agent.py` to call Matrix Hub first (reuse‑first), then fall back to code generation only if no suitable agent is found.

