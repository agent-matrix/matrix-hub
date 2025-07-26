# Development

## Prerequisites
- Python 3.11 or 3.12
- Postgres (optional — SQLite works for unit tests)
- `make` for convenience

## Setup

```bash
python -m venv .venv && source .venv/bin/activate
pip install -U pip
pip install -e .[dev]
cp .env.example .env
make dev
```

## Make targets
* `make dev` — `uvicorn` with auto-reload
* `make run` — foreground server
* `make lint` / `make fmt` — Ruff static checks & formatting
* `make test` — `pytest` test suite
* `make migrate m="msg"` — Alembic revision
* `make upgrade` — apply migrations to head

## Tests
* Unit tests use SQLite by default.
* CI runs on Python 3.11/3.12 (see `.github/workflows/ci.yml`).

## Style
* Ruff enforces formatting and lint rules.
* Prefer type hints and small, composable functions.
* Keep external network operations behind service boundaries.
