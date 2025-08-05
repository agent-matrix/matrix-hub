# src/routes/catalog_list.py
from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from src.db import get_db
from src.models import Entity

router = APIRouter(prefix="/catalog", tags=["catalog"])

@router.get("", summary="List catalog entities")
def list_catalog(db: Session = Depends(get_db)):
    rows = db.query(Entity).order_by(Entity.created_at.desc()).all()
    items = []
    for e in rows:
        items.append({
            "id": e.uid,
            "type": e.type,
            "name": e.name,
            "version": e.version,
            "summary": e.summary,
            "homepage": e.homepage,
            "source_url": e.source_url,
            "created_at": e.created_at,
            "updated_at": e.updated_at,
        })
    return {"items": items, "total": len(items)}
