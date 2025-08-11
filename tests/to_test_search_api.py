# tests/test_search_api.py
from __future__ import annotations

import math

import pytest


def _shape_ok(resp_json):
    assert "items" in resp_json and isinstance(resp_json["items"], list)
    assert "total" in resp_json and isinstance(resp_json["total"], int)


def _assert_scores_not_nan(items):
    for it in items:
        # Scores may be missing or numbers; ensure not NaN if present
        for k in ("score_final", "score_lexical", "score_semantic", "score_quality", "score_recency"):
            v = it.get(k, None)
            if v is not None:
                assert isinstance(v, (int, float)), f"{k} must be a number or null, got {type(v)}"
                assert not math.isnan(v), f"{k} is NaN (normalization bug)"


@pytest.fixture()
def _seed_minimal(client):
    """
    Ensure at least one mcp_server + tool exists via /catalog/install inline manifest.
    This uses the API so we also test the ingest flow.
    """
    payload = {
        "id": "mcp_server:hello-sse-server@0.1.0",
        "target": "./",
        "manifest": {
            "type": "mcp_server",
            "id": "hello-sse-server",
            "name": "Hello World MCP (SSE)",
            "version": "0.1.0",
            "summary": "Hello World service",
            "description": "Say hello",
            "mcp_registration": {
                "tool": {"id": "hello", "name": "hello", "description": "Return greeting", "integration_type": "REST"},
                "server": {"name": "hello-sse-server", "transport": "SSE", "url": "http://localhost:8000/"},
            },
        },
    }
    r = client.post("/catalog/install", json=payload)
    assert r.status_code == 200, r.text


def test_search_mcp_server_keyword_ok(client, _seed_minimal):
    r = client.get(
        "/catalog/search",
        params={
            "q": "Hello World",
            "type": "mcp_server",
            "mode": "keyword",
            "include_pending": "true",
            "limit": 5,
        },
    )
    assert r.status_code == 200, r.text
    data = r.json()
    _shape_ok(data)
    _assert_scores_not_nan(data["items"])


def test_search_tool_keyword_underscore_no_500(client, _seed_minimal):
    # Probe the fragile path that blew up earlier
    r = client.get(
        "/catalog/search",
        params={
            "q": "Hello_World",      # underscore case
            "type": "tool",
            "mode": "keyword",
            "include_pending": "true",
            "limit": 5,
        },
    )
    assert r.status_code == 200, r.text  # Was 500 before
    data = r.json()
    _shape_ok(data)
    _assert_scores_not_nan(data["items"])
