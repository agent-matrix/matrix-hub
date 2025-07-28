"""
Search subsystem factories.

Picks concrete backends based on settings:
- Lexical:  pgtrgm | none
- Vector:   pgvector | none
- Embedder: dummy (pluggable later)
- BlobStore: local-disk (pluggable later)

Also exports lazy singletons:
    lexical_backend, vector_backend, embedder, blobstore
"""

from __future__ import annotations

import os
from functools import lru_cache
from typing import List, Sequence

from ...config import settings
from .interfaces import LexicalBackend, VectorBackend, Embedder, BlobStore


# --------------------------- Null / Dummy implementations ---------------------------

class NullLexicalBackend(LexicalBackend):
    def index(self, docs):  # type: ignore[override]
        return 0

    def upsert(self, docs):  # type: ignore[override]
        return 0

    def delete(self, ids):  # type: ignore[override]
        return 0

    def search(self, query: str, *, type=None, capabilities=None, frameworks=None, providers=None, limit=20):  # type: ignore[override]
        return []


class NullVectorBackend(VectorBackend):
    def upsert_vectors(self, items):  # type: ignore[override]
        return 0

    def delete_vectors(self, entity_uids: Sequence[str]):  # type: ignore[override]
        return 0

    def search(self, query_vec, *, type=None, capabilities=None, frameworks=None, providers=None, limit=20):  # type: ignore[override]
        return []


class DummyEmbedder(Embedder):
    model_id = "dummy-zeros"

    def encode(self, texts: List[str]) -> List[List[float]]:  # type: ignore[override]
        # Return small zero vectors; callers shouldn't rely on dim for the MVP
        return [[0.0] * 16 for _ in texts]


class LocalBlobStore(BlobStore):
    def __init__(self, base_dir: str | None = None) -> None:
        self.base = os.path.abspath(base_dir or settings.BLOB_DIR or "./data/blobs")
        os.makedirs(self.base, exist_ok=True)

    def put_text(self, key: str, text: str) -> str:  # type: ignore[override]
        # Store as a flat file using a sanitized key
        import re
        import pathlib
        safe = re.sub(r"[^A-Za-z0-9._@#-]+", "_", key)
        fpath = pathlib.Path(self.base) / f"{safe}.txt"
        fpath.parent.mkdir(parents=True, exist_ok=True)
        fpath.write_text(text or "", encoding="utf-8")
        return str(fpath)


# --------------------------- Factories ---------------------------

@lru_cache(maxsize=1)
def get_lexical_backend() -> LexicalBackend:
    backend = (settings.SEARCH_LEXICAL_BACKEND or "none").strip().lower()
    try:
        if backend == "pgtrgm":
            from .backends.pgtrgm import PGTrgmBackend  # type: ignore
            return PGTrgmBackend()
    except Exception:
        # Fall through to null backend
        pass
    return NullLexicalBackend()


@lru_cache(maxsize=1)
def get_vector_backend() -> VectorBackend:
    backend = (settings.SEARCH_VECTOR_BACKEND or "none").strip().lower()
    try:
        if backend == "pgvector":
            from .backends.pgvector import PGVectorBackend  # type: ignore
            return PGVectorBackend()
    except Exception:
        pass
    return NullVectorBackend()


@lru_cache(maxsize=1)
def get_embedder() -> Embedder:
    # Placeholder: wire a real model later; keep a small dummy for now
    return DummyEmbedder()


@lru_cache(maxsize=1)
def get_blobstore() -> BlobStore:
    return LocalBlobStore()


# --------------------------- Global singletons (import-friendly) ---------------------------

# These names mirror how other modules import them, e.g.:
#   from src.services.search import lexical_backend
#   from src.services.search.backends import embedder, vector, blobstore
lexical_backend: LexicalBackend = get_lexical_backend()
vector_backend: VectorBackend = get_vector_backend()
embedder: Embedder = get_embedder()
blobstore: BlobStore = get_blobstore()
