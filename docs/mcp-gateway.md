
# MCP Gateway Overview

The MCP Gateway (also known as Context Forge) is the central hub for the Model Context Protocol (MCP), providing:

- **Service registry & discovery:** Agents register themselves and advertise their “tools” (capabilities).
- **Request routing:** All requests go through a single HTTP gateway, which dispatches them to the correct service.
- **Security & authentication:** Supports Basic Auth for user/admin access, and JWTs for fine‑grained, time‑limited tokens.
- **Health monitoring:** Built‑in `/health` endpoint for readiness checks.
- **Local & production modes:** Can run locally in a Python virtualenv or be containerized.

## Key Components

| Component                | Location                        |
|--------------------------|---------------------------------|
| Makefile targets         | top‑level `Makefile`            |
| Setup script             | `scripts/setup-mcp-gateway.sh`  |
| Start/stop scripts       | `scripts/start-mcp-gateway.sh`, `scripts/stop-mcp-gateway.sh` |
| Verification script      | `scripts/verify_servers.sh`     |
| Core code                | `mcpgateway/` directory         |
| Default config template  | `.env.example`                  |

## Getting Started (Local Python Mode)

1. **Setup environment**  
   ```bash
   make gateway-setup
```

This runs `scripts/setup-mcp-gateway.sh` to:

* Check OS compatibility (Ubuntu 22.04 recommended)
* Install Python 3.11 if missing
* Install OS packages: git, curl, jq, etc.
* Clone or update the `IBM/mcp-context-forge` repo at a pinned commit
* Create (or recreate) a Python 3.11 virtualenv
* Install Python dependencies in editable (`.[dev]`) mode
* Copy `.env.example` → `.env` if needed

2. **Start the gateway**

   ```bash
   make gateway-start
   ```

   Invokes `scripts/start-mcp-gateway.sh`, which:

   * Activates virtualenv
   * Loads `.env` vars
   * Initializes the SQLite (or configured) database
   * Launches `mcpgateway` on `$HOST:$PORT` (default `0.0.0.0:4444`)
   * Waits (up to 2 minutes) for `/health` to return `{"status":"ok"}`

3. **Verify it’s running**

   ```bash
   make gateway-verify
   ```

   Runs `scripts/verify_servers.sh`, which checks:

   * HTTP `/health` endpoint
   * Admin `/servers` list (using JWT‑based admin token)
   * Any additional smoke tests

4. **Stop the gateway**

   ```bash
   make gateway-stop
   ```

   Runs `scripts/stop-mcp-gateway.sh` to kill any running `mcpgateway` processes.

