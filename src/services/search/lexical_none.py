# src/services/search/lexical_none.py
from __future__ import annotations

from typing import List, Optional
from sqlalchemy.orm import Session
from sqlalchemy import or_, func

from src.models import Entity


def _escape_like(s: str) -> str:
    """
    Escape SQL LIKE wildcards so they are treated literally.
    Order matters: escape backslash first, then % and _.
    """
    return s.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


def search_like(
    db: Session,
    q: str,
    types: Optional[List[str]] = None,
    include_pending: bool = False,
    limit: int = 50,
    offset: int = 0,
):
    """Naive LIKE-based keyword search for dev/SQLite.

    - Matches case-insensitively across name, summary, description.
    - Optionally restricts to READY-only (default) unless include_pending=True.
    - Returns a list of Entity rows ordered by recency.
    """
    q = (q or "").strip().lower()
    qs = f"%{_escape_like(q)}%" if q else None

    base = db.query(Entity)

    if types:
        base = base.filter(Entity.type.in_(types))

    if not include_pending:
        base = base.filter(
            Entity.gateway_registered_at.isnot(None),
            Entity.gateway_error.is_(None),
        )

    if qs is not None:
        base = base.filter(
            or_(
                func.lower(Entity.name).like(qs, escape="\\"),
                func.lower(Entity.summary).like(qs, escape="\\"),
                func.lower(Entity.description).like(qs, escape="\\"),
            )
        )

    return (
        base.order_by(Entity.created_at.desc())
        .limit(int(limit))
        .offset(int(offset))
        .all()
    )
