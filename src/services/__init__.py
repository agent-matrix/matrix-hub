# src/services/__init__.py
"""
Services package marker.

Provides a tiny "service registry" pattern you can expand later.
Currently exposes lazy accessors for search backends via
src.services.search (lexical, vector, embedder, blobstore).
"""

from __future__ import annotations

from typing import Any, Dict

_registry: Dict[str, Any] = {}


def get_service(name: str, default: Any = None) -> Any:
    return _registry.get(name, default)


def set_service(name: str, value: Any) -> None:
    _registry[name] = value


# Optional re-exports (do NOT import config here; avoid init-time loops)
try:
    from .search import (  # noqa: F401
        get_lexical_backend,
        get_vector_backend,
        get_embedder,
        get_blobstore,
        lexical_backend,
        vector_backend,
        embedder,
        blobstore,
    )
except Exception:
    # Keep package importable even if search backends aren't wired yet
    pass
