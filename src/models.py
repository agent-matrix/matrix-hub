"""
SQLAlchemy models for Matrix Hub.

- Minimal, portable schema that works on SQLite and Postgres
- pg_trgm / pgvector indexes are created via Alembic migrations
- Timestamps and simple __repr__ implementations
"""

from __future__ import annotations

from datetime import datetime
from typing import List, Optional

from sqlalchemy import (
    String,
    Text,
    Float,
    DateTime,
    ForeignKey,
    CheckConstraint,
    Index,
    JSON,
    func,
)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship

# Try to use pgvector type when available; fall back to JSON (portable).
try:
    # pip install pgvector
    from pgvector.sqlalchemy import Vector  # type: ignore
    VECTOR_COLUMN_TYPE = Vector(768)
except Exception:  # pragma: no cover - fallback for dev envs without pgvector
    VECTOR_COLUMN_TYPE = JSON  # stores list[float] as JSON for portability


class Base(DeclarativeBase):
    """Declarative base for the Hub models."""

    repr_cols_num = 4  # pragma: no cover (used in __repr__)

    def __repr__(self) -> str:  # compact, noise-free repr for logs/tests
        values = []
        for col in list(self.__table__.columns)[: self.repr_cols_num]:
            values.append(f"{col.name}={getattr(self, col.name)!r}")
        return f"<{self.__class__.__name__} {' '.join(values)}>"


class Entity(Base):
    """
    Source of truth for published artifacts (agents, tools, mcp_servers).

    Notes:
    - `capabilities`, `frameworks`, `providers` are JSON arrays for portability.
      On Postgres you can still index with GIN in migrations if needed.
    - Trigram (pg_trgm) index on concatenated (name/summary/description) is
      created in Alembic migrations for Postgres.
    """

    __tablename__ = "entity"

    uid: Mapped[str] = mapped_column(String, primary_key=True)
    type: Mapped[str] = mapped_column(
        String,
        nullable=False,
        doc="One of: 'agent' | 'tool' | 'mcp_server'"
    )
    name: Mapped[str] = mapped_column(String, nullable=False)
    version: Mapped[str] = mapped_column(String, nullable=False)

    summary: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    description: Mapped[Optional[str]] = mapped_column(Text, nullable=True)

    license: Mapped[Optional[str]] = mapped_column(String, nullable=True)
    homepage: Mapped[Optional[str]] = mapped_column(String, nullable=True)
    source_url: Mapped[Optional[str]] = mapped_column(String, nullable=True)

    tenant_id: Mapped[str] = mapped_column(String, nullable=False, default="public")

    # JSON lists for portability (works on SQLite & Postgres)
    capabilities: Mapped[List[str]] = mapped_column(JSON, default=list)
    frameworks: Mapped[List[str]] = mapped_column(JSON, default=list)
    providers: Mapped[List[str]] = mapped_column(JSON, default=list)

    readme_blob_ref: Mapped[Optional[str]] = mapped_column(String, nullable=True)

    quality_score: Mapped[float] = mapped_column(Float, nullable=False, default=0.0)
    release_ts: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True), nullable=True)

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now(), nullable=False
    )

    # Relationships
    embedding_chunks: Mapped[list["EmbeddingChunk"]] = relationship(
        back_populates="entity", cascade="all, delete-orphan", passive_deletes=True
    )

    __table_args__ = (
        CheckConstraint("type in ('agent','tool','mcp_server')", name="ck_entity_type"),
        Index("ix_entity_type_name", "type", "name"),
        Index("ix_entity_created_at", "created_at"),
    )


class EmbeddingChunk(Base):
    """
    Semantic chunks associated with an Entity.

    Notes:
    - `vector` uses pgvector when installed; otherwise JSON list[float].
    - ivfflat/HNSW indexes are created in Alembic migrations for Postgres.
    """

    __tablename__ = "embedding_chunk"

    entity_uid: Mapped[str] = mapped_column(
        String,
        ForeignKey("entity.uid", ondelete="CASCADE"),
        primary_key=True
    )
    chunk_id: Mapped[str] = mapped_column(String, primary_key=True)

    vector: Mapped[object] = mapped_column(VECTOR_COLUMN_TYPE, nullable=True)

    caps_text: Mapped[Optional[str]] = mapped_column(String, nullable=True)
    frameworks_text: Mapped[Optional[str]] = mapped_column(String, nullable=True)
    providers_text: Mapped[Optional[str]] = mapped_column(String, nullable=True)

    quality_score: Mapped[Optional[float]] = mapped_column(Float, nullable=True)
    embed_model: Mapped[Optional[str]] = mapped_column(String, nullable=True)
    raw_ref: Mapped[Optional[str]] = mapped_column(String, nullable=True)

    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now(), nullable=False
    )

    entity: Mapped[Entity] = relationship(back_populates="embedding_chunks")

    __table_args__ = (
        Index("ix_embedding_chunk_updated_at", "updated_at"),
    )


class Remote(Base):
    """
    Persisted catalog remotes (index.json URLs).
    """

    __tablename__ = "remote"
    url: Mapped[str] = mapped_column(String, primary_key=True, nullable=False)
