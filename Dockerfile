# Stage 1: Build the virtual environments
FROM python:3.11-slim AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

# Build toolchain & git (for cloning gateway)
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential gcc g++ libpq-dev git \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# --- Hub Setup ---
COPY pyproject.toml README.md ./
COPY src/ ./src/
COPY alembic.ini ./
COPY alembic/ ./alembic/

# Create Hub venv and install (include psycopg for Postgres)
RUN python -m venv /app/.venv && \
    /app/.venv/bin/pip install --upgrade pip && \
    /app/.venv/bin/pip install \
      . \
      'uvicorn[standard]' \
      gunicorn \
      alembic \
      'psycopg[binary]'

# --- Gateway Setup ---
# Allow pinning a specific ref/tag/branch at build time: --build-arg GATEWAY_REF=<ref>
ARG GATEWAY_REF=main
RUN git clone --depth 1 --branch "${GATEWAY_REF}" https://github.com/IBM/mcp-context-forge.git /app/mcpgateway

# Create Gateway venv and install (+ psycopg to support Postgres)
RUN python -m venv /app/mcpgateway/.venv && \
    /app/mcpgateway/.venv/bin/pip install --upgrade pip && \
    /app/mcpgateway/.venv/bin/pip install \
      ./mcpgateway \
      'uvicorn[standard]' \
      gunicorn \
      'psycopg[binary]'

# 🚫 Guard: remove any stray SQLite DBs from the build context (belt-and-suspenders)
RUN find /app -maxdepth 4 \( -name "*.db" -o -name "*.sqlite" -o -name "mcp.db" \) -print -delete || true


# Stage 2: Runtime image
FROM python:3.11-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PATH="/app/.venv/bin:/app/mcpgateway/.venv/bin:${PATH}" \
    INGEST_SCHED_ENABLED=false

# Supervisor to run multiple processes; curl for healthcheck
RUN apt-get update && apt-get install -y --no-install-recommends \
    supervisor curl \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy built app and both virtualenvs
COPY --from=builder /app /app

# Supervisor config (starts hub + gateway)
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# 🚫 Guard again in the final image
RUN find /app -maxdepth 5 \( -name "*.db" -o -name "*.sqlite" -o -name "mcp.db" \) -print -delete || true

# Tiny entrypoint to delete any runtime-stale SQLite DB before Supervisor
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Security: non-root user
RUN groupadd --system app && useradd --system -g app --home /app app && \
    chown -R app:app /app
USER app

EXPOSE 443 4444

# Healthcheck for Hub
HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:443/" >/dev/null || exit 1

# Default: run both via supervisor (entrypoint scrubs any SQLite before start)
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-n", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
