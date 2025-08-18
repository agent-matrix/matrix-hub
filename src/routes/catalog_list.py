# src/routes/catalog_list.py
from typing import Optional

from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session
from sqlalchemy import func

from src.db import get_db
from src.models import Entity

router = APIRouter(prefix="/catalog", tags=["catalog"])


@router.get("", summary="List catalog entities")
def list_catalog(
    db: Session = Depends(get_db),
    limit: int = Query(50, ge=1, le=500),
    offset: int = Query(0, ge=0),
    type: Optional[str] = Query(None, description="agent|tool|mcp_server|any"),
    q: Optional[str] = Query(None, description="name contains (ILIKE/LIKE)"),
):
    base = db.query(
        Entity.uid,
        Entity.type,
        Entity.name,
        Entity.version,
        Entity.summary,
        Entity.homepage,
        Entity.source_url,
        Entity.created_at,
        Entity.updated_at,
    )

    if type and type.lower() != "any":
        base = base.filter(Entity.type == type)

    if q:
        # Use case-insensitive contains on name
        ql = f"%{q.lower().strip()}%"
        base = base.filter(func.lower(Entity.name).like(ql))

    total = base.order_by(None).count()
    rows = (
        base.order_by(Entity.created_at.desc())
        .limit(limit)
        .offset(offset)
        .all()
    )

    items = [
        {
            "id": uid,
            "type": typ,
            "name": name,
            "version": version,
            "summary": summary,
            "homepage": homepage,
            "source_url": source_url,
            "created_at": created_at,
            "updated_at": updated_at,
        }
        for (
            uid,
            typ,
            name,
            version,
            summary,
            homepage,
            source_url,
            created_at,
            updated_at,
        ) in rows
    ]

    return {"items": items, "total": total, "limit": limit, "offset": offset}
