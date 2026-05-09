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
      'psycopg[binary]' \
      'httpx[http2]'

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

# Supervisor to run multiple processes; curl for healthcheck;
# postgresql-client so docker-entrypoint.sh + scripts/select_database_url.sh
# can probe DATABASE_URL_PRIMARY/FALLBACK via psql at boot.
RUN apt-get update && apt-get install -y --no-install-recommends \
    supervisor curl postgresql-client \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy built app and both virtualenvs
COPY --from=builder /app /app

# Copy operational scripts the entrypoint relies on (selector, diagnosis, test_db).
# These live alongside the source and are NOT secrets.
COPY scripts/ /app/scripts/
RUN chmod +x /app/scripts/*.sh || true

# Supervisor config (starts hub + gateway)
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# 🚫 Guard again in the final image
RUN find /app -maxdepth 5 \( -name "*.db" -o -name "*.sqlite" -o -name "mcp.db" \) -print -delete || true

# Tiny entrypoint that resolves DATABASE_URL_PRIMARY / DATABASE_URL_FALLBACK,
# scrubs any leftover SQLite, then exec's supervisord.
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Pre-create the runtime data dir so the named-volume mount inherits the
# right ownership on first use. Without this, docker creates an empty
# `matrixhub_data` volume populated from the image, but with root
# ownership on some hosts — the non-root `app` user then can't write to
# /app/data/blobs and gunicorn workers crash with PermissionError.
RUN mkdir -p /app/data/blobs && chown -R app:app /app

# Security: non-root user (created above as part of `chown -R app:app /app`
# fails without the user existing). Create the user *before* the chown.
RUN groupadd --system app && useradd --system -g app --home /app app && \
    mkdir -p /app/data/blobs && chown -R app:app /app
USER app

EXPOSE 443 4444

# Healthcheck: hit /health over HTTPS (since gunicorn terminates TLS on
# :443 when the Cloudflare Origin Cert is mounted at /etc/ssl/matrixhub).
# -k allows the self-issued Cloudflare Origin Cert (not in the system
# trust store) and -f makes curl fail on non-2xx so the healthcheck
# correctly reflects /health's outcome.
#
# start-period is 60s rather than 40s because the first run may apply
# Alembic migrations against a freshly-provisioned Postgres (a few
# extra seconds beyond the warmup).
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=5 \
  CMD curl -kfsS "https://127.0.0.1:443/health" >/dev/null || exit 1

# Default: run both via supervisor (entrypoint scrubs any SQLite before start)
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-n", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
