# Changelog

## 0.1.0 — Initial Release

- **API**: `/health`, `/catalog/search`, `/catalog/entities/{id}`, `/catalog/install`, `/catalog/remotes`, `/catalog/ingest`
- **Ingest**: `index.json` pull + schema validation
- **Search**: lexical (pg_trgm), semantic (pgvector optional), hybrid ranking
- **Install**: pip/uv, docker, git, zip; adapters; lockfile
- **MCP Gateway**: tool/server registration via admin API
- **Docs**: MkDocs site (Material)
