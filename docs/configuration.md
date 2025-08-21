# Configuration

Matrix Hub is configured entirely via environment variables (see `.env.example`).

| Key | Description | Example |
|---|---|---|
| `DATABASE_URL` | SQLAlchemy URL | `postgresql+psycopg://matrix:matrix@db:5432/matrixhub` |
| `HOST` / `PORT` | Bind address & port | `0.0.0.0` / `443` |
| `API_TOKEN` | Bearer token for admin/protected routes | `supersecret` |
| `MATRIX_REMOTES` | CSV/JSON list of `index.json` URLs to ingest | `https://raw.githubusercontent.com/.../index.json` |
| `INGEST_INTERVAL_MIN` | Background ingestion interval (minutes) | `15` |
| `SEARCH_LEXICAL_BACKEND` | `pgtrgm` or `none` | `pgtrgm` |
| `SEARCH_VECTOR_BACKEND` | `pgvector` or `none` | `none` |
| `EMBED_MODEL` | Embedder model id (informational; pluggable) | `all-MiniLM-L6-v2` |
| `MCP_GATEWAY_URL` | MCP Gateway base URL | `http://mcpgateway:7200` |
| `MCP_GATEWAY_TOKEN` | Bearer for gateway admin API | `supersecret` |

### Notes

- If `API_TOKEN` is set, pass `Authorization: Bearer <token>` on admin calls (`/catalog/ingest`, `/catalog/remotes`).
- For local SQLLite quick trials, you can use `sqlite+pysqlite:///./data/catalog.sqlite`. Some search features (pg_trgm/pgvector) won’t be available.
