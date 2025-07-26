# Matrix Hub

**Matrix Hub** is a central **catalog & installer** for AI **agents**, **tools**, and **MCP servers**.  
It ingests manifests from remote catalogs (e.g., GitHub), powers **search** (lexical & semantic), computes and executes **install plans** (pip/uv, docker, git, zip), writes **adapters** into your project, and optionally registers assets with an **MCP Gateway**.


## How it works?>


Matrix Hub makes managing your AI agents, tools, and MCP servers as simple as browsing a package registry and running installs—you point it at one or more “catalog” URLs (like GitHub-hosted index.json files), it automatically pulls in and validates each manifest, enriches and indexes them for lightning-fast hybrid search (text + vector), then when you run an install it computes an idempotent plan (pip/uv, Docker pull, Git clone, ZIP extract), writes any framework adapters into your project, registers the new services with your MCP Gateway via its normal admin API, and emits a lockfile so you—and your CI—know exactly what’s installed.



### Highlights

- **Reuse-first**: find existing agents/tools before generating new code.
- **Search**: lexical (pg_trgm), semantic (pgvector), **hybrid ranking**.
- **Install**: uv/pip, docker, git, zip with safe defaults & lockfile.
- **MCP Gateway**: register tools/servers using the gateway’s admin API.
- **Governance-ready**: schema validation, basic policy hooks.

---

## High-level architecture

```mermaid
flowchart LR
  subgraph Catalog Authors
    A[agents/tools/mcp servers] --> I[index.json + manifests]
  end
  I -->|ingest| H(Matrix Hub)

  subgraph Dev Environment
    C[matrix CLI / agent-generator] -->|search/install| H
  end

  H -->|register| G[MCP Gateway]
  H -->|adapters & matrix.lock.json| P[Your Project]
```
API: FastAPI on `:7300`
DB: PostgreSQL (SQLite supported for local dev)
Scheduler: periodic ingestion of remote catalogs

### What’s in this release
* Core API: `/health`, `/catalog/search`, `/catalog/entities/{id}`, `/catalog/install`, `/catalog/remotes`, `/catalog/ingest`
* Ingestor: `index.json` pull + schema validation
* Installer: `pip/uv` + `docker` + `git` + `zip`
* MCP Gateway integration: tools & servers (gateway registration)
* Adapters: example templates (LangGraph node, WXO skill stub)
