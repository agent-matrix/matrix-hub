from __future__ import annotations

"""Unit tests for ``services.ingest._maybe_validate``.

Why these matter
----------------
The MatrixHub homepage has three tabs (Agents / Tools / MCP). Validation
failures used to silently drop tool and agent manifests because the
ingest carve-out only covered ``mcp_server`` with empty artifacts. With
the promotion pipeline in mcp_ingest now feeding the catalog, those two
tabs depend on the bypass extending to ``tool`` and ``agent`` whenever
a validator rejects an otherwise-installable manifest.

These tests stub out ``services.validate.validate_manifest`` so the
suite stays offline and deterministic.
"""

import logging
import sys
import types
from typing import Any, Dict

import pytest

from src.services import ingest as ingest_module


# --------------------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------------------


@pytest.fixture
def mock_validate(monkeypatch):
    """Replace services.validate.validate_manifest with a configurable stub.

    Yields the stub's ``calls`` list and a ``set_behaviour`` function so
    each test can decide whether validation passes or raises.
    """
    state: Dict[str, Any] = {"raise": None, "calls": []}

    def fake_validate(manifest: Dict[str, Any]) -> Dict[str, Any]:
        state["calls"].append(dict(manifest))
        if state["raise"] is not None:
            raise state["raise"]
        return manifest

    fake_module = types.ModuleType("src.services.validate")
    fake_module.validate_manifest = fake_validate  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "src.services.validate", fake_module)

    def set_behaviour(*, raises: Exception | None = None) -> None:
        state["raise"] = raises

    yield state, set_behaviour


def _manifest(
    *,
    type_: str = "mcp_server",
    id_: str = "io.example/foo",
    version: str = "1.0.0",
    **extra: Any,
) -> Dict[str, Any]:
    m = {"type": type_, "id": id_, "version": version, "name": "Foo"}
    m.update(extra)
    return m


# --------------------------------------------------------------------------------------
# Behaviour
# --------------------------------------------------------------------------------------


def test_strict_pass_returns_manifest_unchanged(mock_validate):
    state, set_behaviour = mock_validate
    set_behaviour(raises=None)
    m = _manifest()
    assert ingest_module._maybe_validate(m, source="x") == m
    assert len(state["calls"]) == 1


def test_mcp_server_bypass_when_validation_fails(mock_validate, caplog):
    state, set_behaviour = mock_validate
    set_behaviour(raises=ValueError("artifacts: minItems"))
    m = _manifest(type_="mcp_server")
    with caplog.at_level(logging.WARNING):
        out = ingest_module._maybe_validate(m, source="x")
    assert out is m
    assert any("Schema validation failed for mcp_server" in r.message for r in caplog.records)


def test_tool_bypass_when_validation_fails(mock_validate, caplog):
    """Regression: this used to skip-and-empty the Tools tab."""
    state, set_behaviour = mock_validate
    set_behaviour(raises=ValueError("mcp_registration.tool.url: required"))
    m = _manifest(type_="tool", id_="tool.foo.deadbeef")
    with caplog.at_level(logging.WARNING):
        out = ingest_module._maybe_validate(m, source="x")
    assert out is m
    assert any("Schema validation failed for tool" in r.message for r in caplog.records)


def test_agent_bypass_when_validation_fails(mock_validate, caplog):
    """Regression: this used to skip-and-empty the Agents tab."""
    state, set_behaviour = mock_validate
    set_behaviour(raises=ValueError("artifacts: minItems"))
    m = _manifest(type_="agent", id_="agent.foo.deadbeef")
    with caplog.at_level(logging.WARNING):
        out = ingest_module._maybe_validate(m, source="x")
    assert out is m
    assert any("Schema validation failed for agent" in r.message for r in caplog.records)


def test_skip_when_identity_fields_missing(mock_validate):
    """Without (type, id, version) the rest of the pipeline (entity uid,
    dedupe, search) cannot work, so we still raise."""
    state, set_behaviour = mock_validate
    set_behaviour(raises=ValueError("anything"))
    m = _manifest(type_="tool", version="")  # identity incomplete
    with pytest.raises(ingest_module.SkipManifest):
        ingest_module._maybe_validate(m, source="x")


def test_skip_when_type_is_unknown(mock_validate):
    """An unknown ``type`` shouldn't slip past validation. Adding new
    types is a deliberate decision, not a silent fallback."""
    state, set_behaviour = mock_validate
    set_behaviour(raises=ValueError("anything"))
    m = _manifest(type_="dataset")  # not a catalog type
    with pytest.raises(ingest_module.SkipManifest):
        ingest_module._maybe_validate(m, source="x")
