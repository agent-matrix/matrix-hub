"""
Search utilities:

- Filter parsing
- Score normalization (min-max, z-score)
- Recency scoring (time decay)
- Serialization of hits to response payloads
- Rough total estimation
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any, Dict, Iterable, List, Optional, Sequence, Set

from sqlalchemy.orm import Session

from ...models import Entity


# -------- Filters --------

def parse_filters(
    type_: Optional[str],
    capabilities: Optional[str],
    frameworks: Optional[str],
    providers: Optional[str],
) -> Dict[str, Any]:
    def _csv(v: Optional[str]) -> List[str]:
        return [x.strip() for x in (v or "").split(",") if x.strip()]
    return {
        "type": (type_ or "").strip(),
        "capabilities": _csv(capabilities),
        "frameworks": _csv(frameworks),
        "providers": _csv(providers),
    }


def has_overlap(a: Iterable[str] | Set[str], b: Iterable[str] | Set[str]) -> bool:
    sa = set(a or [])
    sb = set(b or [])
    return not sa.isdisjoint(sb)


# -------- Normalization --------

def normalize_minmax(values: Sequence[float]) -> List[float]:
    if not values:
        return []
    vmin = min(values)
    vmax = max(values)
    if vmax <= vmin:
        return [0.0 for _ in values]
    return [(v - vmin) / (vmax - vmin) for v in values]


def normalize_zscore(values: Sequence[float]) -> List[float]:
    if not values:
        return []
    n = float(len(values))
    mean = sum(values) / n
    var = sum((v - mean) ** 2 for v in values) / (n if n > 1 else 1.0)
    std = var ** 0.5
    if std == 0:
        return [0.0 for _ in values]
    # map to approx [0,1] via sigmoid-ish scaling
    return [0.5 + 0.5 * ((v - mean) / (3 * std)) for v in values]


# -------- Quality & recency --------

def compute_recency_score(ts: Optional[datetime], now: Optional[datetime] = None) -> float:
    """
    Exponential time-decay recency score in [0,1].
    Half-life ~ 180 days (configurable by changing HALF_LIFE_DAYS).
    """
    if ts is None:
        return 0.0
    if ts.tzinfo is None:
        # assume UTC if missing
        ts = ts.replace(tzinfo=timezone.utc)
    now = now or datetime.now(tz=timezone.utc)

    HALF_LIFE_DAYS = 180.0
    age_days = max(0.0, (now - ts).total_seconds() / 86400.0)
    # score = 0.5 ** (age / half_life)
    return float(0.5 ** (age_days / HALF_LIFE_DAYS))


# -------- Serialization --------

def serialize_hit(h: Dict[str, Any], db: Session) -> Dict[str, Any]:
    """
    Hydrate a merged/ranked hit with entity metadata for API response.
    Expects keys: 'entity_id', 'score_*'.
    """
    eid = h["entity_id"]
    e: Optional[Entity] = db.get(Entity, eid)
    if not e:
        # Fallback: minimal payload
        return {
            "id": eid,
            "type": "",
            "name": "",
            "version": "",
            "summary": "",
            "capabilities": [],
            "frameworks": [],
            "providers": [],
            "score_lexical": float(h.get("score_lexical", 0.0)),
            "score_semantic": float(h.get("score_semantic", 0.0)),
            "score_quality": float(h.get("score_quality", 0.0)),
            "score_recency": float(h.get("score_recency", 0.0)),
            "score_final": float(h.get("score_final", 0.0)),
        }

    return {
        "id": e.uid,
        "type": e.type,
        "name": e.name,
        "version": e.version,
        "summary": e.summary or "",
        "capabilities": e.capabilities or [],
        "frameworks": e.frameworks or [],
        "providers": e.providers or [],
        "score_lexical": float(h.get("score_lexical", 0.0)),
        "score_semantic": float(h.get("score_semantic", 0.0)),
        "score_quality": float(h.get("score_quality", 0.0)),
        "score_recency": float(h.get("score_recency", 0.0)),
        "score_final": float(h.get("score_final", 0.0)),
    }


# -------- Totals --------

def estimate_total(lex_hits: List[Dict[str, Any]], vec_hits: List[Dict[str, Any]]) -> int:
    """
    Rough total count estimate (distinct entity ids across both hit lists).
    This is a conservative figure because each backend already returned top-K.
    """
    ids = {h.get("entity_id") for h in lex_hits} | {h.get("entity_id") for h in vec_hits}
    return len([i for i in ids if i])
