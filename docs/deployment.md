# Deployment

## Docker Compose (reference)

- See `docker-compose.yaml` included in the repo.
- Exposes the API on `:443` and Postgres on `:5432`.

## Container image

```bash
docker build -t ghcr.io/agent-matrix/matrix-hub:latest .
docker run -p 443:443 --env-file .env ghcr.io/agent-matrix/matrix-hub:latest
```

## Kubernetes (guidance)
* Use a Deployment with 2+ replicas.
* Configure a Secret for `API_TOKEN` and gateway tokens.
* Add a Job or init container to run Alembic migrations before rollout.
* Use a Readiness probe on `/health`.

## Persistence
* Postgres should be backed by persistent volumes.
* The API is stateless (no local writes beyond ephemeral temp files).
