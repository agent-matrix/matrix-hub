import os
from fastapi.testclient import TestClient

# Ensure a local, file‑based SQLite DB for tests; disable remote ingestion
os.environ.setdefault("DATABASE_URL", "sqlite+pysqlite:///./test_ci.sqlite")
os.environ.setdefault("MATRIX_REMOTES", "[]")

from src.app import app  # noqa: E402

client = TestClient(app)


def test_health_ok():
    r = client.get("/health")
    assert r.status_code == 200
    payload = r.json()
    assert payload.get("status") == "ok"
