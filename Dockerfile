# ======================================================================
#  Stage 1: Builder
#    - Create venvs for Hub and Gateway
#    - Install runtime deps (Hub) and run gateway setup script (Gateway)
#    - Keep build tools out of the final image
# ======================================================================
FROM python:3.11-slim AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

# OS deps:
# - build-essential & libpq-dev to compile wheels if needed (psycopg, etc.)
# - git to clone the gateway (if setup script needs it)
# - curl/lsof for port checks (used by our scripts during build debugging if necessary)
# - ca-certificates ensures TLS works for any git/pip operations
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      build-essential gcc g++ \
      libpq-dev \
      git curl ca-certificates \
      lsof netcat-openbsd \
    ; \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy the whole repo (so scripts, mcpgateway/, src/, etc. are available)
COPY . /app

# Ensure scripts are executable (best effort)
RUN set -eux; \
    chmod +x scripts/*.sh || true

# ----------------------------------------------------------------------
# Hub venv (./.venv) — install runtime deps by default
#   You can set HUB_INSTALL_TARGET=dev at build time to install dev extras.
# ----------------------------------------------------------------------
ARG HUB_INSTALL_TARGET=prod
# HUB_INSTALL_TARGET=prod  -> pip install "." + gunicorn + uvicorn + alembic
# HUB_INSTALL_TARGET=dev   -> pip install ".[dev]"

RUN set -eux; \
    python -m venv .venv; \
    . ./.venv/bin/activate; \
    pip install --upgrade pip setuptools wheel; \
    if [ "$HUB_INSTALL_TARGET" = "dev" ]; then \
        echo "Installing Hub (dev) extras..."; \
        pip install ".[dev]"; \
    else \
        echo "Installing Hub (runtime)..."; \
        pip install "."; \
        pip install 'uvicorn[standard]' gunicorn alembic; \
    fi

# ----------------------------------------------------------------------
# Gateway setup — creates mcpgateway/.venv and installs gateway deps
#   (your script may clone/update the gateway, then pip install)
# ----------------------------------------------------------------------
# If you want to skip gateway setup at build time:
#   docker build --build-arg SKIP_GATEWAY_SETUP=1 ...
ARG SKIP_GATEWAY_SETUP=0

RUN set -eux; \
    if [ "$SKIP_GATEWAY_SETUP" = "0" ]; then \
      echo "Running scripts/setup-gateway-container.sh ..."; \
      bash scripts/setup-gateway-container.sh; \
      # Ensure gateway venv has gunicorn/uvicorn for production serving
      if [ -f mcpgateway/.venv/bin/python ]; then \
        . mcpgateway/.venv/bin/activate; \
        pip install --upgrade pip; \
        pip install 'uvicorn[standard]' gunicorn; \
      else \
        echo "WARNING: mcpgateway/.venv missing – check setup script output."; \
      fi; \
    else \
      echo "Skipping gateway setup at build time (SKIP_GATEWAY_SETUP=1)."; \
    fi

# ======================================================================
#  Stage 2: Runtime
#    - Only minimal OS deps
#    - Non-root user
#    - Copy the app and both venvs from the builder
#    - Healthcheck & entrypoint
# ======================================================================
FROM python:3.11-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

# Minimal runtime tools:
# - curl for healthcheck
# - lsof for port checks used by scripts
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      curl lsof netcat-openbsd \
    ; \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy application (including both venvs created in builder)
COPY --from=builder /app /app

# Create non-root user for security
# (UID/GID values chosen to avoid collisions; adjust as needed)
RUN set -eux; \
    addgroup --system app && adduser --system --ingroup app --home /app app; \
    chown -R app:app /app

USER app

# Default ports (can be overridden at runtime):
# - Matrix Hub: 7300
# - MCP-Gateway: 4444
EXPOSE 7300 4444

# Basic healthcheck against Matrix Hub (the gateway is supervised by run_prod.sh)
# You can override PORT via env or .env at runtime.
HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
  CMD bash -c 'curl -fsS "http://127.0.0.1:${PORT:-7300}/" >/dev/null || exit 1'

# Entrypoint starts gateway first, then hub (gunicorn/uvicorn), supervises both.
ENTRYPOINT ["bash", "scripts/run_prod.sh"]
