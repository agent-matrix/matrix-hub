# Container Notes (Matrix Hub + MCP‑Gateway)

This document explains how the Docker image is built and run for **Matrix Hub** together with the **MCP‑Gateway**, and how to operate it in production.

---

## What’s inside the image

* **Two isolated Python virtualenvs**:

  * **Matrix Hub venv:** `/app/.venv`
  * **MCP‑Gateway venv:** `/app/mcpgateway/.venv`
* **Code & scripts:**

  * App code under `/app/src`
  * Gateway project under `/app/mcpgateway`
  * Entrypoint supervisor: `/app/scripts/run_prod.sh`
  * Helper scripts: `/app/scripts/build_container.sh`, `/app/scripts/run_container.sh`
* **Default exposed ports:**

  * **Hub:** `7300`
  * **Gateway:** `4444`
* **Healthcheck:** probes Hub at `http://127.0.0.1:${PORT:-7300}/`.

> The entrypoint (`scripts/run_prod.sh`) launches **Gateway first**, waits for its port, then launches **Matrix Hub**. Both are supervised: if one exits, the other is stopped gracefully.

---

## Environment files

* **Matrix Hub:** root `.env` (copied from `.env.example` if missing).
* **Gateway:** `/app/mcpgateway/.env` (copied from repo’s `.env.gateway.local` during build if present via setup script).

**Important variables:**

* **Hub bind:** `HOST=0.0.0.0`, `PORT=7300`
* **Hub → Gateway integration:** `MCP_GATEWAY_URL=http://127.0.0.1:4444` (or external URL if you skip the embedded gateway)
* **Gateway bind:** `HOST=0.0.0.0`, `PORT=4444`

---

## Building the image

Use the helper script (recommended):

```bash
# Default: runtime deps for Hub, include Gateway setup, tag from git if available
scripts/build_container.sh

# Explicit tag & image name
scripts/build_container.sh --image matrix-hub --tag 1.0.0

# Install Hub dev extras inside the image
scripts/build_container.sh --dev

# Skip bundling the Gateway (use an external one at runtime)
scripts/build_container.sh --skip-gateway-setup

# Target platform (for cross-builders/buildx)
scripts/build_container.sh --platform linux/amd64 --buildx
```

Direct `docker build` (if preferred):

```bash
docker build \
  --build-arg HUB_INSTALL_TARGET=prod \        # or dev
  --build-arg SKIP_GATEWAY_SETUP=0 \           # or 1 to skip
  -t matrix-hub:latest .
```

---

## Running the container

Use the run helper (recommended):

```bash
# Start both Hub (7300) and Gateway (4444), map ports to host
scripts/run_container.sh --image matrix-hub --tag latest

# Run Hub only (skip embedded Gateway) and map Hub to 7310 on host
scripts/run_container.sh --skip-gateway --app-port 7310 --env-file ./.env
```

Key flags:

* `--app-port PORT` → host port for Hub (container 7300)
* `--gw-port PORT` → host port for Gateway (container 4444)
* `--skip-gateway` → do not start the embedded Gateway (sets `GATEWAY_SKIP_START=1`)
* `--env-file PATH` → pass a `.env` for Matrix Hub
* `--data-volume NAME` → persist `/app/data` (Hub data/SQLite)
* `--gw-volume NAME` → persist `/app/mcpgateway/.state` (Gateway state).
  If used, set in Gateway env:

  ```
  DATABASE_URL=sqlite:////app/mcpgateway/.state/mcp.db
  ```

Direct `docker run` example:

```bash
docker run -d --name matrix-hub \
  -p 7300:7300 -p 4444:4444 \
  --env-file ./.env \
  -v matrixhub_data:/app/data \
  matrix-hub:latest
```

---

## Supervisor behavior (`scripts/run_prod.sh`)

* Starts **MCP‑Gateway** first, waits for `:4444` (or gateway’s `PORT`) to listen.
* Starts **Matrix Hub** next on `:7300` (or Hub’s `PORT`).
* Uses **gunicorn + uvicorn workers** when available; falls back to uvicorn.
* **Workers** auto‑calculated as `2*CPU+1` (override via env).
* Graceful shutdown on exit; kills the sibling process if one dies.
* Runs Alembic migrations for Hub if `alembic` and `alembic.ini` are present.

**Tuning via env (override at runtime):**

* **Hub:** `HUB_WORKERS`, `HUB_TIMEOUT`, `HUB_GRACEFUL_TIMEOUT`, `HUB_KEEPALIVE`, `HUB_MAX_REQUESTS`, `HUB_MAX_REQUESTS_JITTER`, `HUB_PRELOAD=true|false`, `HUB_LOG_LEVEL`
* **Gateway:** `GW_WORKERS`, `GW_TIMEOUT`, `GW_GRACEFUL_TIMEOUT`, `GW_KEEPALIVE`, `GW_MAX_REQUESTS`, `GW_MAX_REQUESTS_JITTER`, `GW_PRELOAD=true|false`, `GW_LOG_LEVEL`
* **Skip gateway:** `GATEWAY_SKIP_START=1`
* **Override gateway app path (fallback mode):** `GW_APP_MODULE=mcp_gateway.app:app`

---

## Using an **external** MCP‑Gateway

* Run with `--skip-gateway` (or `GATEWAY_SKIP_START=1`).
* Set **Matrix Hub** `.env`:

  ```
  MCP_GATEWAY_URL=http://<external-gateway-host>:4444
  ```
* Do **not** publish container’s `4444` in that scenario.

---

## Volumes & persistence

* **Hub data:** `/app/data` → mount a named volume (e.g., `matrixhub_data`).
* **Gateway state (optional):** `/app/mcpgateway/.state` → mount a volume (e.g., `mcpgw_data`) and point gateway `DATABASE_URL` at a file in that mount.

---

## Logs

* Both services log to **stdout/stderr** (12‑factor friendly).
* View logs:

  ```bash
  docker logs -f matrix-hub
  ```

---

## Health / readiness

* Dockerfile healthcheck pings Hub at `http://127.0.0.1:${PORT:-7300}/`.
* `scripts/run_container.sh` waits for Hub after start and prints the URLs.

---

## Updating

1. Pull latest code (or update submodules).
2. Rebuild image:

   ```bash
   scripts/build_container.sh -i matrix-hub -t latest
   ```
3. Restart container:

   ```bash
   docker rm -f matrix-hub || true
   scripts/run_container.sh --image matrix-hub --tag latest
   ```

---

## Troubleshooting

* **Port already in use**

  * Change host mapping: `--app-port` / `--gw-port`, or free the port.
* **Gateway module path error** (fallback mode):
  Set `GW_APP_MODULE` to the correct ASGI path (e.g., `my_gateway.main:app`).
* **Hub import errors (e.g., SQLAlchemy)**
  Rebuild image to ensure deps are installed: `scripts/build_container.sh`.
  Locally (non‑container) run `make setup`.
* **Hub cannot reach gateway**
  Check `MCP_GATEWAY_URL` and that gateway is reachable from the Hub container.
  If using embedded gateway, ensure `:4444` is listening inside the container (`docker exec -it matrix-hub sh` then `lsof -nP -i :4444`).
* **Migrations failing**
  Confirm `alembic.ini` exists and DB URL is reachable. Disable migrations by removing `alembic` or the `alembic.ini` file from the image if not used.

---

## Security & ops recommendations

* Run behind a reverse proxy/ingress with **TLS termination**.
* Inject secrets (tokens, DB creds) through **orchestrator secrets** (K8s/Swarm), not baked into images.
* Restrict exposed ports; if using external gateway, **do not expose 4444** from the Hub container.
* Use non‑root (already configured). For stricter profiles, consider:

  * Read‑only root filesystem, `tmpfs` for `/tmp`
  * Drop capabilities (`--cap-drop=ALL`) if feasible
  * Resource limits (CPU/memory) and `ulimit` adjustments as needed

---

## Kubernetes / Compose (high‑level)

* **Kubernetes:** Prefer **separate deployments** for Hub and Gateway. Point the Hub’s `MCP_GATEWAY_URL` at the Gateway service DNS.
* **Docker Compose:** Either use this single image (both processes) or two services (one for Hub, one for Gateway). The latter is recommended for clearer lifecycle and scaling.

---

## Quick references

* **Build:** `scripts/build_container.sh`
* **Run:** `scripts/run_container.sh`
* **Entrypoint:** `scripts/run_prod.sh`
* **Default ports:** Hub `7300`, Gateway `4444`
* **Hub env:** `.env` (copied from `.env.example` if missing)
* **Gateway env:** `mcpgateway/.env` (from gateway setup)
* **Volumes:** `/app/data`, optional `/app/mcpgateway/.state`

---

*End of document.*
