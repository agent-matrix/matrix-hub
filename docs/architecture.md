# Architecture




```mermaid
graph TD
    subgraph User / API Client
        A1[User triggers /ingest or scheduler runs]:::api
        A2[User calls /catalog/install with payload]:::api
    end

    subgraph Matrix Hub FastAPI App
        B1[Fetch index.json from each remote]
        B2[Extract manifest URLs]
        B3[For each manifest<br/> - Fetch and parse<br/> - Validate and ignore empty artifacts for mcp_server]
        B4[Persist entity to DB and commit]
        B5[Chunk and embed long text with fallback]
        B6[Store blobs if any]
        B7[Update search vectors]

        C1[Resolve entity ID and version]
        C2[Fetch manifest from source_url]
        C3[Persist entity to DB and commit]
        C4[Build install plan]
        C5[Install artifacts using pip docker git zip]
        C6[Write adapter code]
        C7[Register in MCP Gateway best effort]
        C8[Write matrix lock json]
    end

    subgraph Matrix Hub DB catalog sqlite
        D1[entity table<br/>gateway_error column]
    end

    subgraph Vector Store and BlobStore optional
        E1[embedding_chunk table]
        E2[blobstore backend]
    end

    subgraph MCP Gateway Service
        F1[POST gates tools etc]
        F2[MCP Gateway DB]
    end

    subgraph Project Folder
        G1[Adapters written]
        G2[matrix lock json]
    end

    %% Ingest workflow
    A1 --> B1
    B1 --> B2
    B2 --> B3
    B3 --> B4
    B4 --> D1
    B3 --> B5
    B5 --> E1
    B5 --> B6
    B6 --> E2
    B5 --> B7

    %% Install workflow
    A2 --> C1
    C1 --> C2
    C2 --> C3
    C3 --> D1
    C2 --> C4
    C4 --> C5
    C5 --> G1
    C4 --> C6
    C6 --> G1
    C4 --> C7
    C7 --> F1
    F1 --> F2
    C7 --> D1
    C4 --> C8
    C8 --> G2

    classDef api fill:#E3E7F3,stroke:#0C2A51,color:#0C2A51
    class A1,A2 api
```


```mermaid
graph TD
    subgraph User/API Client
        A1[User triggers /ingest or scheduler runs]:::api
        A2[User calls /catalog/install with payload]:::api
    end

    subgraph Matrix Hub FastAPI App
        B1[Fetch index.json from each remote]
        B2[Extract manifest URLs]
        B3[For each manifest:<br/> - Fetch & parse<br/> - Validate]
        B4[save_entitymanifest, db<br/>Upsert to Hub DB]
        B5[Chunk & embed long text]
        B6[Store blobs if any]
        B7[Update search vectors]

        C1[Resolve entity ID, version]
        C2[Fetch manifest from source_url]
        C3[save_entitymanifest, db<br/>Upsert to Hub DB]
        C4[Build install plan]
        C5[Install artifacts pip/docker/git/zip]
        C6[Write adapter code]
        C7[Register in MCP-Gateway]
        C8[Write matrix.lock.json]
    end

    subgraph "Matrix Hub DB catalog.sqlite"
        D1[entity table]
    end

    subgraph "Vector Store/BlobStore optional"
        E1[embedding_chunk table]
        E2[blobstore backend]
    end

    subgraph "MCP-Gateway Service"
        F1[POST /gateways, /tools, ...]
        F2[MCP-Gateway DB]
    end

    subgraph "Project Folder"
        G1[Adapters written]
        G2[matrix.lock.json]
    end

    %% Ingest workflow
    A1 --> B1
    B1 --> B2
    B2 --> B3
    B3 --> B4
    B4 --> D1
    B3 --> B5
    B5 --> E1
    B5 --> B6
    B6 --> E2
    B5 --> B7

    %% Install workflow
    A2 --> C1
    C1 --> C2
    C2 --> C3
    C3 --> D1
    C2 --> C4
    C4 --> C5
    C5 --> G1
    C4 --> C6
    C6 --> G1
    C4 --> C7
    C7 --> F1
    F1 --> F2
    C4 --> C8
    C8 --> G2

    %% Styles
    classDef api fill:#E3E7F3,stroke:#0C2A51,color:#0C2A51;
    class A1,A2 api;

```



## Components

- **API** (FastAPI): search, entities, install, remotes, ingest trigger.
- **DB** (PostgreSQL): normalized entity metadata, artifacts, tags, capabilities.
- **Ingestor**: pulls `index.json`, validates manifests, upserts entities.
- **Installer**: executes artifact steps, writes adapters, updates lockfile, registers with MCP Gateway.
- **Scheduler**: periodic ingestion via APScheduler.

## Data model (high level)

- `entity` — `(uid, type, name, version, summary, description, capabilities[], frameworks[], providers[], source_url, created_at, updated_at, provenance)`
- `artifact` — `(entity_id, kind, uri, hash, size, install_hint)`
- `tag` & `entity_tag`, `capability` & `entity_capability` (many-to-many)
- optional `embedding_chunk` (when using vector search)

## Diagram

```mermaid
flowchart TD
  subgraph Ingest
    R[Remote index.json] --> V[Validate schemas]
    V --> U[Upsert DB]
  end
  subgraph API
    S[Search] -->|rank| O[Response]
    E[Entity detail] --> O
    I[Install] --> P[Project files + lockfile]
    I --> G[MCP Gateway]
  end
  DB[(Postgres)] <--> S
  DB <--> E
  DB <--> U
```
## Scaling
* Swap lexical backend to OpenSearch and vector backend to Milvus without changing the public API.
* Keep Matrix Hub stateless; scale horizontally.
