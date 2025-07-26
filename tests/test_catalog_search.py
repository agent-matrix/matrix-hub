import os
from typing import Generator

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

# Make sure we don't accidentally hit Postgres in CI
os.environ.setdefault("DATABASE_URL", "sqlite+pysqlite:///./test_ci.sqlite")
os.environ.setdefault("MATRIX_REMOTES", "[]")

from src.app import app
from src.db import get_db
from src.models import Base, Entity


@pytest.fixture(scope="module")
def engine():
    eng = create_engine("sqlite+pysqlite:///./test_search.sqlite", future=True)
    Base.metadata.create_all(eng)
    yield eng
    Base.metadata.drop_all(eng)


@pytest.fixture(scope="module")
def Session(engine):
    return sessionmaker(bind=engine, autoflush=False, autocommit=False, future=True)


@pytest.fixture(autouse=True, scope="module")
def override_db(Session) -> Generator:
    def _get_db():
        db = Session()
        try:
            yield db
        finally:
            db.close()

    app.dependency_overrides[get_db] = _get_db
    yield
    app.dependency_overrides.pop(get_db, None)


@pytest.fixture(autouse=True)
def seed(Session):
    db = Session()
    try:
        # Clear
        db.query(Entity).delete()
        # Seed a few entities
        e1 = Entity(
            uid="agent:pdf-summarizer@1.0.0",
            type="agent",
            name="PDF Summarizer",
            version="1.0.0",
            summary="Summarizes PDF files",
            description="An agent that summarizes PDF documents.",
            capabilities=["pdf", "summarize"],
            frameworks=["langgraph"],
            providers=["watsonx"],
        )
        e2 = Entity(
            uid="tool:table-extractor@0.3.0",
            type="tool",
            name="Table Extractor",
            version="0.3.0",
            summary="Extracts tables from PDFs",
            description="Tool for extracting tables.",
            capabilities=["pdf", "extract"],
            frameworks=["crewai"],
            providers=["openai"],
        )
        e3 = Entity(
            uid="mcp_server:files@2.1.0",
            type="mcp_server",
            name="Files MCP Server",
            version="2.1.0",
            summary="File ops",
            description="MCP server for file operations.",
            capabilities=["fs", "read", "write"],
            frameworks=[],
            providers=[],
        )
        db.add_all([e1, e2, e3])
        db.commit()
        yield
    finally:
        db.close()


client = TestClient(app)


def _assert_search_schema(body):
    assert "items" in body and isinstance(body["items"], list)
    assert "total" in body and isinstance(body["total"], int)
    for it in body["items"]:
        assert "id" in it and "type" in it and "name" in it and "version" in it
        assert "score_final" in it
        # These fields may be empty lists depending on backend
        assert "capabilities" in it
        assert "frameworks" in it
        assert "providers" in it


def test_search_keyword_ok():
    r = client.get("/catalog/search", params={"q": "pdf", "type": "agent", "mode": "keyword"})
    assert r.status_code == 200
    _assert_search_schema(r.json())


def test_search_semantic_ok():
    r = client.get("/catalog/search", params={"q": "summarize documents", "mode": "semantic"})
    assert r.status_code == 200
    _assert_search_schema(r.json())


def test_search_hybrid_with_filters_ok():
    r = client.get(
        "/catalog/search",
        params={
            "q": "pdf",
            "type": "tool",
            "capabilities": "extract",
            "frameworks": "crewai",
            "providers": "openai",
            "mode": "hybrid",
            "limit": 10,
        },
    )
    assert r.status_code == 200
    _assert_search_schema(r.json())
