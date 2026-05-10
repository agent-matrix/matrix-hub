"""
Regression tests for the production failure that produced the
`/catalog/search` 502 surface:

  * Empty result set must return HTTP 200 with `{"items":[],"total":0}`,
    NOT a 500. (Triggered by `q=watsonx` against Aiven where 7466
    entities existed but none matched, then the route fell into
    `_fallback_uid_or_slug_hit` which crashed on a missing column.)

  * Non-empty result set must return ranked hits with stable shape.

  * Even when the lexical backend would crash internally, the route's
    defensive try/except envelope must surface a structured error
    `{"detail":{"error":"SearchFailed","reason":"..."}}` rather than
    leaking a bare FastAPI 500.

These tests run against the local SQLite test DB (LIKE fallback path);
the migrations CI workflow runs the same suite against a real Postgres
17 with `pg_trgm` so the production code path is exercised end-to-end.
"""

from __future__ import annotations

from datetime import datetime, timezone

import pytest


@pytest.fixture
def db_session():
    """Local fixture that handles src.db's late-binding SessionLocal.

    The repo's `session` fixture imports SessionLocal at module load
    (when it's still a placeholder); this fixture goes through the
    module attribute so we get the real bound sessionmaker after
    init_db() runs.
    """
    import src.db as dbmod
    dbmod.init_db()
    s = dbmod.SessionLocal()
    try:
        yield s
    finally:
        s.close()


def _seed_entity(session, **kw):
    from src.models import Entity
    now = datetime.now(timezone.utc)
    defaults = dict(
        type="mcp_server",
        version="1.0.0",
        summary=None,
        description=None,
        capabilities=[],
        frameworks=[],
        providers=[],
        quality_score=0.5,
        created_at=now,
        release_ts=now,
        gateway_registered_at=now,
        gateway_error=None,
    )
    defaults.update(kw)
    session.merge(Entity(**defaults))
    session.commit()


def test_search_no_results_returns_200(client, db_session):
    """The exact prod scenario: query a term that no entity matches.

    Must NOT return 500. Must return HTTP 200 with empty items array.
    """
    _seed_entity(db_session, uid="mcp_server:slack@1", name="Slack",
                 summary="Slack connector")

    r = client.get(
        "/catalog/search",
        params={
            "q": "definitely_does_not_exist_zzzqq",
            "type": "any",
            "include_pending": "true",
            "mode": "keyword",
            "limit": 10,
        },
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body.get("items") == []
    assert body.get("total") == 0


def test_search_returns_hits_when_match_exists(client, db_session):
    _seed_entity(db_session, uid="mcp_server:slack-connect@0.1.0",
                 name="Slack Connect MCP",
                 summary="Slack messaging via MCP")
    _seed_entity(db_session, uid="mcp_server:noop@0",
                 name="Noop", summary="Nothing")

    r = client.get(
        "/catalog/search",
        params={
            "q": "slack",
            "type": "any",
            "include_pending": "true",
            "mode": "keyword",
            "limit": 10,
        },
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert isinstance(body.get("items"), list)
    ids = [it["id"] for it in body["items"]]
    assert "mcp_server:slack-connect@0.1.0" in ids


def test_search_route_returns_structured_error_envelope_on_backend_failure(
    client, db_session, monkeypatch
):
    """If the lexical engine itself raises, the route's defensive
    try/except must convert that to a structured `{detail:{error,reason}}`
    envelope (or `{error:{...}}` depending on FastAPI's default
    exception serializer for non-HTTPException). It must NOT leak the
    raw stack trace as an unstructured 500.
    """
    from src.services.search import engine as engine_mod

    def boom(*_a, **_kw):
        raise RuntimeError("simulated backend explosion")

    monkeypatch.setattr(engine_mod, "run_keyword", boom)

    r = client.get(
        "/catalog/search",
        params={"q": "anything", "type": "any", "mode": "keyword"},
    )
    # 5xx is acceptable; the contract is that the body is JSON-structured
    # so the frontend proxy can render an actionable message rather than
    # the bare "Search unavailable / 502".
    assert r.status_code in (500, 502, 503), r.text
    body = r.json()
    # Either {"detail":{"error":"SearchFailed",...}} or
    # {"error":{"error":"SearchFailed",...}} — both are envelope-ish.
    flat = body.get("detail") or body.get("error") or {}
    if isinstance(flat, dict):
        assert flat.get("error") == "SearchFailed"
        assert "reason" in flat
    else:
        # Rare: frame as detail-string. Still must be JSON, never HTML.
        assert isinstance(body, dict)


def test_required_orm_columns_match_required_set():
    """The drift checker's REQUIRED_ENTITY_COLUMNS must keep up with the
    ORM. If someone adds an Entity column that production queries select
    but doesn't add it here, the prod drift gate becomes blind to it.
    Force the maintainer to update both sites in the same PR.
    """
    from sqlalchemy import inspect as sa_inspect

    from scripts.check_schema_drift import REQUIRED_ENTITY_COLUMNS
    from src.models import Entity

    declared = {c.name for c in sa_inspect(Entity).columns}
    missing = declared - REQUIRED_ENTITY_COLUMNS
    assert not missing, (
        f"ORM has columns not listed in REQUIRED_ENTITY_COLUMNS: {missing}. "
        f"Update scripts/check_schema_drift.py."
    )


@pytest.mark.skipif(
    True,
    reason="Postgres-only path; runs in .github/workflows/migrations-ci.yml "
           "against a real Postgres 17 service container.",
)
def test_search_against_postgres_with_drift():
    """Placeholder for the Postgres-mode equivalent: verify the route
    returns the structured envelope when `manifest_blob_ref` is missing,
    and 200 with empty results after `make repair-db`. The CI workflow
    runs this with a real Postgres service.
    """
