# syntax=docker/dockerfile:1

############################
# Builder
############################
FROM python:3.12-slim AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

# Create a virtualenv to copy into the runtime image
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

WORKDIR /app

# Install build deps only if needed (kept small since we use psycopg[binary])
RUN pip install --upgrade pip

# Copy project metadata and sources
COPY pyproject.toml ./
COPY src ./src

# Install the app into the venv
RUN pip install .

############################
# Runtime
############################
FROM python:3.12-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# Bring the prebuilt virtualenv
COPY --from=builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# App source (for runtime templates/static and to enable stack traces)
COPY src ./src

EXPOSE 7300

# Run with uvicorn (proxy headers allow running behind reverse proxies)
CMD ["uvicorn", "src.app:app", "--host", "0.0.0.0", "--port", "7300", "--proxy-headers"]
