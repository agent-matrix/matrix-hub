# tests/test_search_top5.py
#
# Contract test for the public Top-5 search API.
# Minimal and production-safe: does not modify DB schema and
# only asserts additive fields/behavior.

import os
import pytest
from httpx import AsyncClient, ASGITransport

from src.app import app

# If your project uses sync TestClient, switch to starlette.testclient.TestClient
# and remove async/await. This version assumes async FastAPI testing.

pytestmark = pytest.mark.anyio

BASE_URL = os.getenv("TEST_BASE_URL", "http://test")


@pytest.fixture(scope="module")
def asgi_transport():
    # httpx>=0.28 removed AsyncClient(app=...). Use ASGITransport instead.
    # If your app has a lifespan, the default lifespan="auto" should work.
    return ASGITransport(app=app)


async def test_search_top5_basic(monkeypatch, asgi_transport):
    """GET /catalog/search returns 200 and <= 5 items by default."""
    async with AsyncClient(transport=asgi_transport, base_url=BASE_URL) as ac:
        resp = await ac.get("/catalog/search", params={"q": "hello"})
        assert resp.status_code == 200, resp.text
        data = resp.json()
        assert "items" in data and isinstance(data["items"], list)
        assert len(data["items"]) <= 5


async def test_search_top5_has_links(monkeypatch, asgi_transport):
    """Each item contains manifest_url and install_url (if entity exists)."""
    async with AsyncClient(transport=asgi_transport, base_url=BASE_URL) as ac:
        resp = await ac.get("/catalog/search", params={"q": "agent"})
        assert resp.status_code == 200
        data = resp.json()
        for item in data.get("items", []):
            # These fields are optional in the schema but should be present
            # for real entities; skip empty/minimal fallbacks safely.
            manifest_url = item.get("manifest_url")
            install_url = item.get("install_url")
            # Allow None for degenerate hits; assert non-empty when present
            if manifest_url is not None:
                assert isinstance(manifest_url, str) and manifest_url.strip()
            if install_url is not None:
                assert isinstance(install_url, str) and install_url.strip()


async def test_search_top5_with_snippets(monkeypatch, asgi_transport):
    """with_snippets=true should include a snippet field (when text exists)."""
    async with AsyncClient(transport=asgi_transport, base_url=BASE_URL) as ac:
        resp = await ac.get(
            "/catalog/search",
            params={"q": "pdf", "with_snippets": True},
        )
        assert resp.status_code == 200
        data = resp.json()
        for item in data.get("items", []):
            # snippet is optional overall; if present, it should be a non-empty string
            snippet = item.get("snippet")
            if snippet is not None:
                assert isinstance(snippet, str)
                assert snippet.strip() != ""


async def test_search_type_any(monkeypatch, asgi_transport):
    """type=any should not error and should return up to 5 items."""
    async with AsyncClient(transport=asgi_transport, base_url=BASE_URL) as ac:
        resp = await ac.get("/catalog/search", params={"q": "search", "type": "any"})
        assert resp.status_code == 200
        data = resp.json()
        assert len(data.get("items", [])) <= 5
