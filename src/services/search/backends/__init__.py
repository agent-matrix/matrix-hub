"""
Backends registry proxies.

Some parts of the code import:
    from src.services.search.backends import embedder, vector, blobstore

To keep those imports working while still choosing implementations via settings,
we expose thin proxy objects that delegate to the real singletons created in
src.services.search.
"""

from __future__ import annotations

from typing import Any, Dict, Iterable, List, Sequence

from .. import get_embedder, get_vector_backend, get_blobstore


class _EmbedderProxy:
    @property
    def model_id(self) -> str:
        return getattr(get_embedder(), "model_id", "unknown")

    def encode(self, texts: List[str]) -> List[List[float]]:
        return get_embedder().encode(texts)


class _VectorProxy:
    def upsert_vectors(self, items: Iterable[Dict[str, Any]]) -> int:
        return get_vector_backend().upsert_vectors(items)

    def delete_vectors(self, entity_uids: Sequence[str]) -> int:
        return get_vector_backend().delete_vectors(entity_uids)

    def search(self, query_vec, **filters) -> List[Dict[str, Any]]:
        return get_vector_backend().search(query_vec, **filters)


class _BlobStoreProxy:
    def put_text(self, key: str, text: str) -> str:
        return get_blobstore().put_text(key, text)


# Proxies exported at module level
embedder = _EmbedderProxy()
vector = _VectorProxy()
blobstore = _BlobStoreProxy()

# Optional convenience factories for explicit imports
def pgtrgm_factory():
    from .pgtrgm import PGTrgmBackend  # type: ignore
    return PGTrgmBackend()

def pgvector_factory():
    from .pgvector import PGVectorBackend  # type: ignore
    return PGVectorBackend()
