# Catalog Manifests

Matrix Hub consumes **manifests** stored in your catalog repo and indexed by an `index.json`.

## Types

- **Agent** — `agent.manifest.yaml`
- **Tool** — `tool.manifest.yaml`
- **MCP Server** — `mcp-server.manifest.yaml`

## Core fields

- `schema_version`, `type`, `id`, `name`, `version`, `description`, `license`
- `capabilities`, `compatibility` (frameworks/providers)
- `artifacts` — list of `{ kind: pypi|oci|git|zip, spec: {...} }`
- `endpoints` (optional)
- `mcp_registration` (optional)
- `adapters` (optional)

## Example — Agent

```yaml
schema_version: 1
type: agent
id: pdf-summarizer
name: PDF Summarizer
version: 1.4.2
description: Summarizes long PDF documents.
capabilities: [pdf, summarize]
compatibility:
  frameworks: [langgraph]
  providers: [watsonx]
artifacts:
  - kind: pypi
    spec: { package: "pdf-summarizer-agent", version: "==1.4.2" }
adapters:
  - framework: langgraph
    template_key: langgraph-node
mcp_registration:
  tool:
    name: pdf_summarize
    integration_type: REST
    request_type: POST
    url: [https://example.com/invoke](https://example.com/invoke)
    input_schema: { type: object, properties: { input: { type: string } }, required: [input] }
```

## Schemas
* `schemas/agent.manifest.schema.json`
* `schemas/tool.manifest.schema.json`
* `schemas/mcp-server.manifest.schema.json`

During ingestion, schemas are validated; invalid manifests are skipped with warnings.
