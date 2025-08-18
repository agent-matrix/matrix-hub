# src/services/search/engine.py
from __future__ import annotations

from typing import List, Optional, Dict

from sqlalchemy.orm import Session
from sqlalchemy import func

from src.config import settings
from src.models import Entity

from .interfaces import Hit
from .util import compute_recency_score, normalize_minmax
from .lexical_none import search_like

# Try to load the pg_trgm backend (prod path). Safe if unavailable in dev.
try:
    from .backends import pgtrgm as pgtrgm_backend
except Exception:  # pragma: no cover
    pgtrgm_backend = None  # type: ignore


def _filter_ready_hits(db: Session, hits: List[Hit]) -> List[Hit]:
    """
    READY-only filter: keep hits whose entities have gateway_registered_at set and no gateway_error.
    No-ops if hits is empty.
    """
    if not hits:
        return hits

    ids = [h.entity_id for h in hits]
    rows = (
        db.query(Entity.uid, Entity.gateway_registered_at, Entity.gateway_error)
        .filter(Entity.uid.in_(ids))
        .all()
    )
    ready_ids = {
        r.uid
        for r in rows
        if (getattr(r, "gateway_registered_at", None) is not None)
        and (getattr(r, "gateway_error", None) is None)
    }
    return [h for h in hits if h.entity_id in ready_ids]


def _ready_filter_query(qb, include_pending: bool):
    """Apply READY-only filter to an ORM query when include_pending=False."""
    if not include_pending:
        qb = qb.filter(
            Entity.gateway_registered_at.isnot(None),
            Entity.gateway_error.is_(None),
        )
    return qb


def _fallback_uid_or_slug_hit(
    db: Session,
    q: str,
    types: Optional[List[str]],
    include_pending: bool,
) -> List[Hit]:
    """
    Fallback for exact UID or slug-in-UID queries when the primary lexical
    backend returns no hits.

    - If q looks like a full UID (contains ':' and '@'), try exact case-insensitive uid match.
    - Else, try to find q as the slug segment inside uid via '%:slug@%'.
    Returns at most one Hit with score=1.0.
    """
    qn = (q or "").strip()
    if not qn:
        return []

    ql = qn.lower()
    qb = db.query(Entity)

    if ":" in ql and "@" in ql:
        qb = qb.filter(func.lower(Entity.uid) == ql)
    else:
        qb = qb.filter(func.lower(Entity.uid).like(f"%:{ql}@%"))

    if types:
        qb = qb.filter(Entity.type.in_(types))

    qb = _ready_filter_query(qb, include_pending)
    ent = qb.order_by(Entity.created_at.desc()).first()
    if not ent:
        return []

    ts = ent.release_ts or ent.created_at
    return [
        Hit(
            entity_id=ent.uid,
            score=1.0,                 # lead when user typed an exact/slug id
            source="lexical",          # <-- IMPORTANT: ensure ranker doesn't drop it
            quality=float(ent.quality_score or 0.0),
            recency=compute_recency_score(ts),
        )
    ]


def run_pgtrgm(
    db: Session,
    q: str,
    types: Optional[List[str]],
    include_pending: bool,
    limit: int,
    offset: int,
) -> List[Hit]:
    """
    Production lexical path via Postgres + pg_trgm backend.
    Adapts args to backend API and (optionally) enforces READY-only.
    """
    if pgtrgm_backend is None:
        return []

    # Build backend filters (pgtrgm backend expects a single 'type' value, not a list)
    filters: Dict = {
        "type": (types[0] if types else None) or "",
        "capabilities": [],
        "frameworks": [],
        "providers": [],
    }

    # k is the top-k target (backend expands internally)
    k = max(int(limit), 1)

    try:
        hits: List[Hit] = pgtrgm_backend.search(q=q, filters=filters, k=k, db=db)
    except Exception:
        # Defensive: never let backend errors bubble up to the route
        hits = []

    if not include_pending:
        hits = _filter_ready_hits(db, hits)

    # Offset handling (cheap slice); pg_trgm backend doesn't support offset natively
    if offset:
        hits = hits[offset:]
    hits = hits[:limit]

    # If nothing matched via normal lexical fields, try a single UID/slug fallback.
    if not hits:
        return _fallback_uid_or_slug_hit(db, q, types, include_pending)

    return hits


def run_keyword(
    db: Session,
    q: str,
    types: Optional[List[str]],
    include_pending: bool,
    limit: int,
    offset: int,
) -> List[Hit]:
    """
    Keyword search dispatcher.
    - pgtrgm in prod (SEARCH_LEXICAL_BACKEND=pgtrgm)
    - LIKE fallback when SEARCH_LEXICAL_BACKEND=none (SQLite/dev)
    Returns a list[Hit] compatible with ranker.merge_and_score.
    """
    backend = getattr(settings, "SEARCH_LEXICAL_BACKEND", "none").lower()

    if backend == "pgtrgm":
        return run_pgtrgm(db, q, types, include_pending, limit, offset)

    # Dev fallback — LIKE over name/summary/description; returns Entity rows
    entities: List[Entity] = search_like(
        db=db,
        q=q,
        types=types,
        include_pending=include_pending,
        limit=limit + offset,  # fetch enough to honor offset below
        offset=0,
    )

    # Compute a crude lexical score based on matches across fields.
    q_l = (q or "").strip().lower()
    sims_raw: List[float] = []
    meta: List[Dict] = []

    for e in entities:
        name = (e.name or "").lower()
        summary = (e.summary or "").lower()
        description = (e.description or "").lower()
        hits = 0
        if q_l and q_l in name:
            hits += 1
        if q_l and q_l in summary:
            hits += 1
        if q_l and q_l in description:
            hits += 1
        sims_raw.append(hits / 3.0 if q_l else 0.0)
        meta.append(
            {
                "uid": e.uid,
                "ts": (e.release_ts or e.created_at),
                "quality": float(e.quality_score or 0.0),
            }
        )

    # Zero-range guard to avoid NaN/inf from normalization
    if sims_raw:
        lo, hi = min(sims_raw), max(sims_raw)
        if hi <= lo:
            sims = [0.0] * len(sims_raw)
        else:
            sims = normalize_minmax(sims_raw)
    else:
        sims = []

    all_hits: List[Hit] = []
    for i, m in enumerate(meta):
        rec = compute_recency_score(m["ts"])
        all_hits.append(
            Hit(
                entity_id=m["uid"],
                score=(sims[i] if i < len(sims) else 0.0),
                source="lexical",
                quality=m["quality"],
                recency=rec,
            )
        )

    # Honor offset/limit
    if offset:
        all_hits = all_hits[offset:]
    sliced = all_hits[:limit]

    # If LIKE returned nothing, try the same UID/slug fallback used in pg_trgm path.
    if not sliced:
        return _fallback_uid_or_slug_hit(db, q, types, include_pending)

    return sliced
