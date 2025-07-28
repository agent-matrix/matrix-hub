"""
Vector backend using pgvector, with a safe no-op fallback when unavailable.

- Primary path (Postgres + pgvector): cosine distance (`<=>`) between query
  vector and chunk vectors, grouped by entity, picking the best (min distance).
- Fallback (SQLite/other OR missing pgvector): return [] to avoid false results.
"""

from __future__ import annotations

from typing import Dict, List

from sqlalchemy import text, bindparam
from sqlalchemy.engine import Engine
from sqlalchemy.orm import Session

from ..interfaces import Hit
from ..util import (
    compute_recency_score,
    has_overlap,
    normalize_minmax,
)


def _is_postgres(engine: Engine) -> bool:
    name = (engine.dialect.name or "").lower()
    return name == "postgresql"


def _supports_pgvector(engine: Engine) -> bool:
    # Heuristic: if dialect is postgres, assume pgvector available.
    # In production you may want a feature flag or a one-time probe.
    return _is_postgres(engine)


def search(q_vector: List[float], filters: Dict, k: int, db: Session) -> List[Hit]:
    """
    Return vector hits for entities by grouping best chunk distance and
    converting to normalized semantic score in [0,1] (1 - cosine_distance).
    """
    engine = db.get_bind()
    if not _supports_pgvector(engine):
        return []

    # NOTE: cosine distance is in [0, 2] theoretically, but pgvector's cosine
    # returns (1 - cosine_similarity), so distance in [0, 2], best = 0.
    # We'll normalize to similarity ~ (1 - dist), then min-max after retrieval.

    sql = text(
        """
        SELECT
          e.uid,
          e.type,
          e.name,
          e.version,
          e.summary,
          e.capabilities,
          e.frameworks,
          e.providers,
          e.quality_score,
          COALESCE(e.release_ts, e.created_at) AS ts,
          MIN(ec.vector <=> :qvec) AS dist,                -- cosine distance
          (ARRAY_AGG(ec.chunk_id ORDER BY (ec.vector <=> :qvec) ASC))[1] AS best_chunk
        FROM embedding_chunk ec
        JOIN entity e ON e.uid = ec.entity_uid
        GROUP BY e.uid, e.type, e.name, e.version, e.summary, e.capabilities, e.frameworks,
                 e.providers, e.quality_score, e.release_ts, e.created_at
        ORDER BY dist ASC
        LIMIT :limit
        """
    ).bindparams(
        bindparam("qvec", value=q_vector),  # SQLAlchemy will adapt list -> vector param on PG
        bindparam("limit", value=max(k * 4, 50)),
    )

    rows = db.execute(sql).mappings().all()
    candidates = [dict(r) for r in rows]

    # Apply filters in Python for portability
    f_type = (filters.get("type") or "").strip()
    fcaps = set(filters.get("capabilities") or [])
    ffw   = set(filters.get("frameworks") or [])
    fprov = set(filters.get("providers") or [])

    filtered: List[dict] = []
    for row in candidates:
        if f_type and row.get("type") != f_type:
            continue
        if fcaps and not has_overlap(fcaps, set(row.get("capabilities") or [])):
            continue
        if ffw and not has_overlap(ffw, set(row.get("frameworks") or [])):
            continue
        if fprov and not has_overlap(fprov, set(row.get("providers") or [])):
            continue
        filtered.append(row)

    # Convert distance to similarity (approx): sim_raw = max(0.0, 1.0 - float(r["dist"]))
    sims_raw = [max(0.0, 1.0 - float(r["dist"])) for r in filtered] or [0.0]
    sims = normalize_minmax(sims_raw)

    hits: List[Hit] = []
    for idx, row in enumerate(filtered[:k]):
        rec = compute_recency_score(row.get("ts"))
        qual = float(row.get("quality_score") or 0.0)
        hits.append(
            Hit(
                entity_id=row["uid"],
                score=sims[idx],
                source="vector",
                quality=qual,
                recency=rec,
                best_chunk_id=(row.get("best_chunk") or ""),
            )
        )
    return hits


def upsert_vectors(items):
    """
    Stub for API-compatibility. In this architecture, vector ingestion is done
    via SQLAlchemy ORM in the ingestion pipeline, so this is a no-op here.
    """
    return None


def delete_vectors(entity_ids):
    """
    Stub for API-compatibility. Prefer ON DELETE CASCADE via foreign key in DB.
    """
    return None
