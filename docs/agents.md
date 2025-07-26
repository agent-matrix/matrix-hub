# Agents, Tools, and MCP Servers (Concepts)

Matrix Hub catalogs three entity types:

- **Agent**: an orchestrated capability (often a service with `/invoke`).
- **Tool**: a callable function/tool (often REST or MCP tool).
- **MCP Server**: a server that exposes MCP protocol endpoints and tools.

## Manifests

Each entity has a manifest describing:

- Identity: `type`, `id`, `name`, `version`
- Metadata: `summary`, `description`, `license`, `homepage`
- Capabilities/tags; compatibility (frameworks/providers)
- Artifacts: `pypi | oci | git | zip` with specs
- Adapters: framework glue to drop into your project
- `mcp_registration`: how to register with MCP Gateway
