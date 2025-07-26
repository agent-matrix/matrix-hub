# Install & Registration

## Install steps

- **pypi** — `uv pip install` (with `pip` fallback)
- **oci** — `docker pull`
- **git** — `git clone` and optional `checkout`
- **zip** — download & extract (hash-checked when `digest` is provided)

Each step is **idempotent** where possible (e.g., docker pull, git checkout).

## Adapters

- Manifest `adapters` entries instruct Matrix Hub to write glue code/templates into your project:
  - Example: LangGraph node in `src/flows/...`
  - Example: WatsonX Orchestrate `skill.yaml`
- Files are listed under `files_written` and referenced in `matrix.lock.json`.

## Lockfile

`matrix.lock.json` captures:
- Entity ID & version
- Artifacts resolved
- Adapters written
- Provenance (manifest URL, optional commit)

## MCP Gateway registration

If the manifest contains `mcp_registration`:
- **tool** — POST `/tools` (integration_type: REST/MCP, request_type, url, input_schema)
- **server** — POST `/gateways` (transport: SSE/HTTP/STDIO/STREAMABLEHTTP)
- **resources/prompts** — POST `/resources`, `/prompts`

> Some gateways perform discovery automatically after registration. Matrix Hub’s gateway client supports this by design.
