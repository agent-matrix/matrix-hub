"""
Lexical backend using Postgres pg_trgm similarity, with a portable fallback.

- Primary path (Postgres + pg_trgm): use `similarity()` over (name, summary, description)
  and order by the best similarity score.
- Fallback (SQLite/other): naive LIKE ranking for development to avoid hard failures.

Filters (type, capabilities, frameworks, providers) are applied in Python after
retrieval to keep SQL portable across engines.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Dict, List

from sqlalchemy import text
from sqlalchemy.engine import Engine
from sqlalchemy.orm import Session

from ....models import Entity
from ..interfaces import Hit
from ..util import (
    compute_recency_score,
    has_overlap,
    normalize_minmax,
)


def _is_postgres(engine: Engine) -> bool:
    name = (engine.dialect.name or "").lower()
    return name == "postgresql"


def _fetch_candidates_pg(db: Session, q: str, k: int) -> List[dict]:
    """
    Use pg_trgm similarity across name/summary/description; pick the max per row.
    """
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
          GREATEST(
            similarity(e.name, :q),
            similarity(COALESCE(e.summary,''), :q),
            similarity(COALESCE(e.description,''), :q)
          ) as sim
        FROM entity e
        WHERE (e.name ILIKE :ilq OR e.summary ILIKE :ilq OR e.description ILIKE :ilq)
        ORDER BY sim DESC
        LIMIT :limit
        """
    )
    rows = db.execute(sql, {"q": q, "ilq": f"%{q}%", "limit": max(k * 4, 50)}).mappings().all()
    return [dict(r) for r in rows]


def _fetch_candidates_fallback(db: Session, q: str, k: int) -> List[dict]:
    """
    Portable fallback for engines without pg_trgm. Gives a crude score:
    count of case-insensitive matches across fields / 3.
    """
    q_l = q.lower()
    rows = (
        db.query(
            Entity.uid,
            Entity.type,
            Entity.name,
            Entity.version,
            Entity.summary,
            Entity.capabilities,
            Entity.frameworks,
            Entity.providers,
            Entity.quality_score,
            Entity.release_ts,
            Entity.created_at,
        )
        .all()
    )

    scored: List[dict] = []
    for r in rows:
        name = (r.name or "").lower()
        summary = (r.summary or "").lower()
        # We don't have description here; keep it simple for fallback
        hits = 0
        hits += 1 if q_l in name else 0
        hits += 1 if q_l in summary else 0
        score = hits / 2.0  # crude score in [0,1]
        scored.append(
            dict(
                uid=r.uid,
                type=r.type,
                name=r.name,
                version=r.version,
                summary=r.summary,
                capabilities=r.capabilities or [],
                frameworks=r.frameworks or [],
                providers=r.providers or [],
                quality_score=r.quality_score or 0.0,
                ts=(r.release_ts or r.created_at),
                sim=score,
            )
        )

    scored.sort(key=lambda d: d["sim"], reverse=True)
    return scored[: max(k * 4, 50)]


def search(q: str, filters: Dict, k: int, db: Session) -> List[Hit]:
    """
    Return lexical hits with normalized similarity (0..1), basic quality/recency.
    """
    engine = db.get_bind()
    if _is_postgres(engine):
        candidates = _fetch_candidates_pg(db, q, k)
    else:
        candidates = _fetch_candidates_fallback(db, q, k)

    # Apply filters in Python (portable across engines)
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

    # Normalize similarity to [0,1]
    sims = [r["sim"] for r in filtered] or [0.0]
    sims_norm = normalize_minmax(sims)

    hits: List[Hit] = []
    now = datetime.now(tz=timezone.utc)
    for idx, row in enumerate(filtered[:k]):
        rec = compute_recency_score(row.get("ts"), now=now)
        qual = float(row.get("quality_score") or 0.0)
        hits.append(
            Hit(
                entity_id=row["uid"],
                score=sims_norm[idx],
                source="lexical",
                quality=qual,
                recency=rec,
            )
        )
    return hits
