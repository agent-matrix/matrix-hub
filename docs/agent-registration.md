# Registration with MCP Gateway

After installing, Matrix Hub can register entities with MCP Gateway via its admin API.

## What Gets Registered

- **Tools**: `POST /tools` with `name`, `integration_type (REST|MCP)`, `request_type`, `url`, `input_schema`, and optional headers/annotations.
- **MCP Servers**: `POST /gateways` with `name`, `url`, `transport (HTTP/SSE/STDIO/STREAMABLEHTTP)`, and optional auth.
  - Discovery of tools is **automatic** after registration; no separate endpoint needed.
- **Resources / Prompts** (optional): added via `POST /resources` / `POST /prompts`.

## Idempotency & Conflicts

- Re-registration with identical payloads may yield `409 Conflict`; Matrix Hub surfaces this in the install results.
- Admin token is required; set `MCP_GATEWAY_TOKEN`.

## Security

- Use Gateway over TLS.
- Store auth tokens outside source control (`.env`, secret manager).
