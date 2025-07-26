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


# Re-export search singletons for convenience
try:
    from .search import (  # type: ignore
        get_lexical_backend,
        get_vector_backend,
        get_embedder,
        get_blobstore,
    )
except Exception:  # pragma: no cover
    # If search isn't fully wired in a given environment, keep imports optional
    pass
