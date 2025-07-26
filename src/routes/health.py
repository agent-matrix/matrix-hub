"""
Health endpoints for Matrix Hub.

- GET /health : returns {"status": "ok"} for simple smoke tests
- Optional DB connectivity probe via ?check_db=true
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, Query
from sqlalchemy import text
from sqlalchemy.orm import Session

from ..db import get_db

router = APIRouter(tags=["health"])


@router.get("/health")
def health(check_db: bool = Query(False), db: Session = Depends(get_db)):
    """
    Lightweight liveness/readiness endpoint.
    By default only returns {"status": "ok"}.
    If `check_db=true`, runs a fast DB query and adds {"db": "ok"|"error"}.
    """
    payload = {"status": "ok"}
    if check_db:
        try:
            db.execute(text("SELECT 1"))
            payload["db"] = "ok"
        except Exception:
            payload["db"] = "error"
    return payload
