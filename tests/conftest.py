"""
Global pytest configuration for Matrix Hub tests.

Goals
-----
- Keep tests fully local/offline (SQLite, no remote ingest).
- Disable background scheduler by default.
- Provide small conveniences (quiet logging, optional TestClient fixture).
- Clean up temporary SQLite files created by tests.
- Ensure search runs in "dev" mode (no external vector/lexical backends).
- Enable tool derivation during tests (so /catalog/install creates tool rows).

Notes
-----
Individual tests may still override the DB session dependency or set their own
DATABASE_URLs. We simply provide safe defaults here so importing `src.app`
doesn't try to reach external services.
"""

from __future__ import annotations

import logging
import os
from pathlib import Path
from typing import Generator, List

import pytest

# ---------------------------------------------------------------------
# Environment defaults (must be set BEFORE importing application code)
# ---------------------------------------------------------------------
# Local SQLite DB for tests. Keep the simple driver so it works everywhere.
os.environ.setdefault("DATABASE_URL", "sqlite:///./ci.sqlite")

# Disable remote ingestion & background scheduler for tests.
os.environ.setdefault("CATALOG_REMOTES", "[]")
os.environ.setdefault("INGEST_INTERVAL_MIN", "0")
os.environ.setdefault("INGEST_SCHED_ENABLED", "false")

# Keep logs quiet in CI unless a test explicitly raises the level.
os.environ.setdefault("LOG_LEVEL", "WARNING")

# Disable admin auth by default in tests (routes can still add Depends).
os.environ.setdefault("API_TOKEN", "")

# Provide harmless gateway defaults; tests stub actual network calls.
os.environ.setdefault("MCP_GATEWAY_URL", "http://localhost:7200")
os.environ.setdefault("MCP_GATEWAY_TOKEN", "")

# --- Search / RAG defaults for tests (pure local) --------------------
# Force lexical fallback and disable vector backends.
os.environ.setdefault("SEARCH_LEXICAL_BACKEND", "none")
os.environ.setdefault("SEARCH_VECTOR_BACKEND", "none")
# Make hybrid default predictable (still works with "none" backends).
os.environ.setdefault("SEARCH_DEFAULT_MODE", "hybrid")
# Disable RAG & reranking by default in tests.
os.environ.setdefault("RAG_ENABLED_DEFAULT", "false")
os.environ.setdefault("RERANK_DEFAULT", "none")
# Enable tool derivation so /catalog/install produces tool rows in tests.
os.environ.setdefault("DERIVE_TOOLS_FROM_MCP", "true")

# ---------------------------------------------------------------------
# Logging hygiene for noisy libraries
# ---------------------------------------------------------------------
logging.getLogger("uvicorn").setLevel(logging.WARNING)
logging.getLogger("uvicorn.access").setLevel(logging.WARNING)
logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("sqlalchemy.engine").setLevel(logging.WARNING)


# ---------------------------------------------------------------------
# Optional FastAPI TestClient fixture (most tests import app directly)
# ---------------------------------------------------------------------
@pytest.fixture
def client():
    """
    Provide a ready-to-use TestClient if a test prefers DI style.

    Usage:
        def test_health(client):
            r = client.get("/health")
            assert r.status_code == 200
    """
    from fastapi.testclient import TestClient
    from src.app import app

    return TestClient(app)


# ---------------------------------------------------------------------
# Auto-cleanup of temporary SQLite files created during the test run
# ---------------------------------------------------------------------
@pytest.fixture(scope="session", autouse=True)
def _cleanup_sqlite_files() -> Generator[None, None, None]:
    """
    Remove common SQLite files produced by tests to keep the workspace clean.
    """
    # Pre-clean to avoid state leakage between runs
    for p in ("./ci.sqlite", "./test_ci.sqlite", "./test_search.sqlite", "./test_install.sqlite"):
        try:
            Path(p).unlink(missing_ok=True)
        except Exception:
            pass

    yield

    # Post-clean (best-effort)
    candidates: List[Path] = [
        Path("./ci.sqlite"),
        Path("./test_ci.sqlite"),
        Path("./test_search.sqlite"),
        Path("./test_install.sqlite"),
    ]
    for p in candidates:
        try:
            if p.exists():
                p.unlink()
        except Exception:
            # On Windows or locked handles in CI, ignore failure silently.
            pass


# ---------------------------------------------------------------------
# Ensure scheduler is stopped at the end of the session (belt & braces)
# ---------------------------------------------------------------------
@pytest.fixture(scope="session", autouse=True)
def _ensure_scheduler_stopped() -> Generator[None, None, None]:
    """
    Tests set INGEST_INTERVAL_MIN=0, so the scheduler should not start.
    As an extra guard, attempt to stop it on teardown if present.
    """
    yield
    try:
        from src.app import app  # lazy import to avoid side effects early
        from src.workers.scheduler import stop_scheduler

        # Pass the scheduler instance from app.state, not the app itself.
        scheduler = getattr(app.state, "scheduler", None)
        if scheduler:
            stop_scheduler(scheduler)
    except Exception:
        # If imports fail or scheduler wasn't started, ignore.
        pass


# --- DB Session fixture -------------------------------------------------------
@pytest.fixture
def session():
    """
    Provide a real SQLAlchemy Session bound to the test database.
    Uses src.db init to ensure schema is present.
    """
    from src.db import init_db, SessionLocal

    init_db()            # builds engine(s) and ensures schema
    db = SessionLocal()  # write-capable session
    try:
        yield db
    finally:
        db.close()
