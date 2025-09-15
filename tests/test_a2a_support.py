# tests/test_a2a_support.py
"""
A2A upgrade smoke tests.

These tests are intentionally lightweight and offline-friendly:
- They verify that ingestion persists `manifests.a2a` and tags `entity.protocols`.
- They verify gateway client wrappers for A2A forward the idempotent flag and token override.
- They verify the A2A-ready read DTO parses protocol markers and manifests.
"""

from __future__ import annotations

# --- Force local SQLite & disable remotes BEFORE importing app modules ----------------
import os

# Hard override so we never hit Postgres even if .env sets it
os.environ["DATABASE_URL"] = "sqlite+pysqlite:///./test_a2a.sqlite"
os.environ.setdefault("MATRIX_REMOTES", "[]")
os.environ.setdefault("SEARCH_LEXICAL_BACKEND", "none")
os.environ.setdefault("SEARCH_VECTOR_BACKEND", "none")

from typing import Any, Dict, List, Optional

import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import Session, sessionmaker

from src.models import Base, Entity
from src.services.ingest import ingest_manifest
from src.services import gateway_client as gw
from src.schemas import EntityRead


# --------------------------------------------------------------------------------------
# Local DB fixtures (override conftest.session to avoid init_db() using Postgres)
# --------------------------------------------------------------------------------------

@pytest.fixture
def session() -> Session:
    """
    Provide an isolated SQLite session for this test module only.
    This avoids calling src.db.init_db() (which could read .env and try Postgres).
    """
    engine = create_engine("sqlite+pysqlite:///:memory:", future=True)
    Base.metadata.create_all(engine)
    SessionLocal = sessionmaker(bind=engine, autoflush=False, autocommit=False, future=True)
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
        # No drop_all on in-memory DB needed; it disappears when engine is GC'd.


# --------------------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------------------

def _uid(m: Dict[str, Any]) -> str:
    return f"{m['type']}:{m['id']}@{m['version']}"


def _make_a2a_manifest(
    *,
    agent_id: str = "hello-a2a",
    version: str = "0.1.0",
    a2a_version: str = "1.0",
    endpoint: str = "http://localhost:9999",
) -> Dict[str, Any]:
    return {
        "schema_version": 1,
        "type": "agent",
        "id": agent_id,
        "version": version,
        "name": "Hello A2A",
        "summary": "Minimal A2A agent for tests",
        # New protocol-native manifests block
        "manifests": {
            "a2a": {
                "version": a2a_version,
                "endpoint_url": endpoint,
                "agent_type": "jsonrpc",
                "auth": {"type": "none", "value": ""},
                "tags": ["demo", "test"],
            }
        },
    }


# --------------------------------------------------------------------------------------
# Tests
# --------------------------------------------------------------------------------------

def test_ingest_persists_a2a_protocol_and_manifest(session: Session):
    """
    GIVEN a manifest with `manifests.a2a`
    WHEN ingest_manifest is called with do_embed=False
    THEN entity.manifests["a2a"] is stored AND `a2a@<ver>` appears in entity.protocols
    """
    m = _make_a2a_manifest()
    entity = ingest_manifest(m, db=session, do_embed=False)

    # The upsert returns the in-session entity; verify PK and attrs.
    assert isinstance(entity, Entity)
    assert entity.uid == _uid(m)

    # Ensure the manifests block is persisted
    assert isinstance(entity.manifests, dict), "entity.manifests should be a dict"
    assert "a2a" in entity.manifests, "entity.manifests must include 'a2a' key"
    assert entity.manifests["a2a"]["endpoint_url"] == m["manifests"]["a2a"]["endpoint_url"]

    # Ensure stable protocol tag is present (sorted + deduped semantics upstream)
    assert isinstance(entity.protocols, list), "entity.protocols should be a list"
    assert f"a2a@{m['manifests']['a2a']['version']}" in entity.protocols


def test_gateway_client_a2a_wrappers_forward_token_and_idempotent(monkeypatch: pytest.MonkeyPatch):
    """
    GIVEN the module-level wrappers:
        - register_a2a_agent(agent_spec, idempotent, token)
        - create_server_with_a2a(server_spec, idempotent, token)
    WHEN we call them
    THEN they forward `override_token` and `idempotent` correctly to the client.
    """
    calls: List[Dict[str, Any]] = []

    class StubClient:
        def create_a2a_agent(self, payload: Dict[str, Any], *, idempotent: bool = False, override_token: Optional[str] = None):
            calls.append({"fn": "a2a", "payload": payload, "idempotent": idempotent, "token": override_token})
            return {"ok": True, "kind": "a2a", "idempotent": idempotent, "token": override_token, "name": payload.get("name")}

        def create_server(self, payload: Dict[str, Any], *, idempotent: bool = False, override_token: Optional[str] = None):
            calls.append({"fn": "server", "payload": payload, "idempotent": idempotent, "token": override_token})
            return {"ok": True, "kind": "server", "idempotent": idempotent, "token": override_token, "name": payload.get("name")}

    # Ensure register_* wrappers use our stubbed client
    stub = StubClient()
    monkeypatch.setattr(gw, "_client", lambda: stub)

    # Exercise A2A registration wrapper
    token = "Bearer test-token-123"
    a2a_payload = {
        "name": "test-a2a-agent",
        "endpoint_url": "http://localhost:9999",
        "agent_type": "jsonrpc",
        "auth_type": "none",
        "auth_value": None,
        "tags": ["ci"],
    }
    r1 = gw.register_a2a_agent(a2a_payload, idempotent=True, token=token)
    assert r1["ok"] is True
    assert r1["kind"] == "a2a"
    assert r1["idempotent"] is True
    assert r1["token"] == token

    # Exercise server creation wrapper (association with a2a agents happens server-side)
    server_payload = {
        "name": "test-a2a-server",
        "description": "CI virtual server",
        "associated_a2a_agents": ["test-a2a-agent"],
    }
    r2 = gw.create_server_with_a2a(server_payload, idempotent=True, token=token)
    assert r2["ok"] is True
    assert r2["kind"] == "server"
    assert r2["idempotent"] is True
    assert r2["token"] == token

    # Verify we actually captured both calls and the parameters are correct
    assert [c["fn"] for c in calls] == ["a2a", "server"]
    assert calls[0]["payload"]["name"] == "test-a2a-agent"
    assert calls[0]["idempotent"] is True and calls[0]["token"] == token
    assert calls[1]["payload"]["name"] == "test-a2a-server"
    assert calls[1]["idempotent"] is True and calls[1]["token"] == token


def test_entityread_parses_protocols_and_manifests():
    """
    Ensure the public DTO accepts protocol markers and protocol-native manifests (non-breaking).
    """
    dto = EntityRead(
        id="agent:hello-a2a@0.1.0",
        type="agent",
        name="Hello A2A",
        version="0.1.0",
        protocols=["a2a@1.0", "mcp@0.1"],
        manifests={"a2a": {"version": "1.0", "endpoint_url": "http://localhost:9999"}},
        capabilities=["demo"],
        frameworks=[],
        providers=[],
        quality_score=0.0,
        created_at="2024-01-01T00:00:00Z",
        updated_at="2024-01-01T00:00:00Z",
    )
    assert "a2a@1.0" in dto.protocols
    assert "a2a" in (dto.manifests or {})
    assert dto.manifests["a2a"]["endpoint_url"] == "http://localhost:9999"
