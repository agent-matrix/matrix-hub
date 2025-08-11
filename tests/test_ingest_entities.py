# tests/test_ingest_entities.py
from __future__ import annotations

from datetime import datetime

from sqlalchemy import select

from src.models import Entity


def test_ingest_basic_server(session):
    # minimal realistic manifest
    manifest = {
        "type": "mcp_server",
        "id": "hello-sse-server",
        "name": "Hello World MCP (SSE)",
        "version": "0.1.0",
        "summary": "Simple SSE server for Hello World",
        "description": "Returns greetings over SSE.",
        "source_url": "https://example.com/hello-sse-server.manifest.json",
        "capabilities": ["hello"],
        "frameworks": ["example"],
        "providers": ["self"],
        "mcp_registration": {
            "tool": {
                "id": "hello",
                "name": "hello",
                "description": "Return a simple greeting.",
                "integration_type": "REST",
            },
            "server": {"name": "hello-sse-server", "transport": "SSE", "url": "http://localhost:8000/"},
        },
        "release_ts": datetime.utcnow().isoformat(),
    }

    # Import save_entity after fixtures configured DB
    from src.db import save_entity

    ent = save_entity(manifest, session)  # should commit
    assert ent.uid == "mcp_server:hello-sse-server@0.1.0"

    # Verify it’s in DB
    row = session.execute(select(Entity).where(Entity.uid == ent.uid)).scalar_one()
    assert row.name == "Hello World MCP (SSE)"
    assert row.summary
    assert row.description
