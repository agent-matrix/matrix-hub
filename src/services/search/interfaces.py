"""
Search interfaces (protocols) for pluggable backends.

These define the minimal contract the rest of the app relies on. Concrete
implementations live under `backends/` (e.g., pgtrgm, pgvector).
"""

from __future__ import annotations

from typing import Any, Dict, Iterable, List, Optional, Protocol, TypedDict


class Hit(TypedDict, total=False):
    """
    Generic hit structure produced by backends.

    Required:
      - entity_id: unique id of the entity (e.g., "agent:pdf-summarizer@1.4.2")
      - score: backend-specific score (already normalized to [0, 1] if possible)

    Optional extras:
      - source: "lexical" | "vector"
      - quality: float      # quality signal (0..1)
      - recency: float      # recency signal (0..1)
      - best_chunk_id: str  # for vector hits (best matching chunk)
    """
    entity_id: str
    score: float
    source: str
    quality: float
    recency: float
    best_chunk_id: str


class LexicalBackend(Protocol):
    """Keyword/BM25-ish search over entity text fields."""

    def index(self, docs: Iterable[Dict[str, Any]]) -> None:
        """Optional: update index with docs (no-op for DB-driven backends)."""
        ...

    def delete(self, ids: Iterable[str]) -> None:
        """Optional: delete docs (no-op for DB-driven backends)."""
        ...

    def search(self, q: str, filters: Dict[str, Any], k: int, **kwargs) -> List[Hit]:
        """
        Execute lexical search.
        Returns a list of hits with normalized 'score' in [0,1] when possible.
        """
        ...


class VectorBackend(Protocol):
    """ANN search over embedding chunks joined to entities."""

    def upsert_vectors(self, items: Iterable[Dict[str, Any]]) -> None:
        """Insert/update chunk vectors; item keys match `embedding_chunk` schema."""
        ...

    def delete_vectors(self, entity_ids: Iterable[str]) -> None:
        """Delete all vectors for the given entities."""
        ...

    def search(self, q_vector: List[float], filters: Dict[str, Any], k: int, **kwargs) -> List[Hit]:
        """
        Execute ANN search with a pre-encoded query vector.
        Returns a list of hits with normalized 'score' in [0,1] when possible.
        """
        ...


class Embedder(Protocol):
    """Sentence/embedding encoder used by ingestion and vector query encoding."""

    @property
    def model_id(self) -> str:  # e.g., "all-MiniLM-L12-v2@2025-02"
        ...

    def encode(self, texts: List[str]) -> List[List[float]]:
        """Return a list of L2-normalized vectors (preferred)."""
        ...


class BlobStore(Protocol):
    """Access raw chunk text or READMEs for RAG 'fit_reason' and indexing."""

    def put_text(self, key: str, text: str) -> str:
        """Store text under a key and return a canonical reference (URI/path)."""
        ...

    def get_text(self, key: str) -> str:
        """Fetch text for a key; should return '' if missing (not raise)."""
        ...
