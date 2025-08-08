from __future__ import annotations

import json
import logging
from typing import Any, Dict, List, Optional, Set
from dataclasses import asdict
from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, HttpUrl, field_validator
from sqlalchemy.orm import Session

from ..config import settings
from ..db import get_db
from ..models import Remote
from ..utils.security import require_api_token
from ..services.ingest import ingest_index
from ..services.install import sync_registry_gateways

log = logging.getLogger(__name__)
router = APIRouter(tags=["remotes"])


# --------------------------------------------------------------------------------------
# Pydantic models
# --------------------------------------------------------------------------------------

class RemoteItem(BaseModel):
    url: HttpUrl


class RemoteListResponse(BaseModel):
    items: List[RemoteItem]
    count: int


class RemoteCreateRequest(BaseModel):
    url: HttpUrl


class RemoteCreateResponse(BaseModel):
    added: bool
    url: HttpUrl
    total: int


class RemoteDeleteResponse(BaseModel):
    removed: bool
    url: str
    total: int


class IngestRequest(BaseModel):
    url: Optional[HttpUrl] = None

    @field_validator("url", mode="before")
    @classmethod
    def blank_to_none(cls, v: Any) -> Any:
        return v or None


class IngestItemResult(BaseModel):
    url: str
    ok: bool
    stats: Optional[Dict[str, Any]] = None
    error: Optional[str] = None


class IngestResponse(BaseModel):
    results: List[IngestItemResult]



class RemoteCreateRequest(BaseModel):
    url: HttpUrl


class RemoteCreateResponse(BaseModel):
    added: bool
    url: HttpUrl
    total: int

class RemoteDeleteResponse(BaseModel):
    removed: bool
    url: HttpUrl
    total: int


# --------------------------------------------------------------------------------------
# Helper: runtime fallback store (if DB empty)
# --------------------------------------------------------------------------------------

def _parse_initial_remotes() -> Set[str]:
    raw = settings.MATRIX_REMOTES
    urls: List[str] = []
    if isinstance(raw, (list, tuple)):
        urls = [str(u).strip() for u in raw if str(u).strip()]
    elif isinstance(raw, str):
        s = raw.strip()
        if s:
            try:
                arr = json.loads(s)
                if isinstance(arr, list):
                    urls = [str(u).strip() for u in arr if str(u).strip()]
                else:
                    urls = [s]
            except Exception:
                urls = [u.strip() for u in s.split(",") if u.strip()]
    seen: Set[str] = set()
    out: List[str] = []
    for u in urls:
        if u not in seen:
            seen.add(u)
            out.append(u)
    return set(out)


# --------------------------------------------------------------------------------------
# Endpoints
# --------------------------------------------------------------------------------------

@router.post("/remotes/sync")
def sync_remotes(db: Session = Depends(get_db)):
    """
    Trigger a full sync: ingest all configured remotes into Matrix Hub,
    then re-affirm their registration in MCP-Gateway.

    Returns a summary of ingested URLs, any errors, and whether gateways were synced.
    """
    # Gather all remote URLs from the DB; if empty, seed from MATRIX_REMOTES
    remotes = [r.url for r in db.query(Remote).all()]
    seeded = False
    if not remotes:
        initial = sorted(_parse_initial_remotes())
        if initial:
            for u in initial:
                db.add(Remote(url=u))
            db.commit()
            seeded = True
            remotes = [r.url for r in db.query(Remote).all()]

    if not remotes:
        # Still nothing to ingest; return early with a clear status
        return {"status": "no remotes configured", "seeded": seeded}

    success: List[str] = []
    failures: Dict[str, str] = {}

    # 1) Ingest each remote index.json, committing on success or rolling back on failure
    for url in remotes:
        try:
            ingest_index(db=db, index_url=url)
            db.commit()                    # Persist ingest results immediately
            success.append(url)
        except Exception as e:
            db.rollback()                  # Undo partial work for this URL
            log.warning("Ingest failed for %s: %s", url, e)
            failures[url] = str(e)

    # 2) Re-register gateways only if at least one ingest succeeded
    synced = False
    if success:
        try:
            sync_registry_gateways(db)
            synced = True
        except Exception as e:
            log.exception("Gateway sync failed after ingest")
            raise HTTPException(status_code=500, detail=f"Gateway sync error: {e}")

    # Return detailed summary
    return {
        "seeded": seeded,
        "ingested": success,
        "errors": failures,
        "synced": synced,
        "count": len(remotes),
    }




@router.get("/remotes", response_model=RemoteListResponse)
def list_remotes(db: Session = Depends(get_db)) -> RemoteListResponse:
    """List all remotes from the database."""
    rows = db.query(Remote).order_by(Remote.url).all()
    items = [RemoteItem(url=r.url) for r in rows]
    # Fallback: if DB empty but settings provide defaults
    if not items and settings.MATRIX_REMOTES:
        for u in sorted(_parse_initial_remotes()):
            db.add(Remote(url=u))
        db.commit()
        rows = db.query(Remote).order_by(Remote.url).all()
        items = [RemoteItem(url=r.url) for r in rows]
    return RemoteListResponse(items=items, count=len(items))


@router.post(
    "/remotes",
    response_model=RemoteCreateResponse,
    status_code=status.HTTP_201_CREATED,
    dependencies=[Depends(require_api_token)]
)
def create_remote(
    req: RemoteCreateRequest,
    db: Session = Depends(get_db)
) -> RemoteCreateResponse:
    """
    Add a new remote index URL to the catalog.
    """
    url_str = str(req.url)

    # Check if it already exists
    existing = db.query(Remote).filter(Remote.url == url_str).first()
    total = db.query(Remote).count()
    if existing:
        return RemoteCreateResponse(added=False, url=req.url, total=total)

    # Insert the new remote
    db.add(Remote(url=url_str))
    db.commit()

    # Return updated total
    total = db.query(Remote).count()
    return RemoteCreateResponse(added=True, url=req.url, total=total)


@router.delete(
    "/remotes",
    response_model=RemoteDeleteResponse,
    status_code=status.HTTP_200_OK,
    dependencies=[Depends(require_api_token)]
)
def delete_remote(
    req: RemoteCreateRequest,
    db: Session = Depends(get_db)
) -> RemoteDeleteResponse:
    """
    Remove an existing remote index URL from the catalog.
    """
    url_str = str(req.url)

    # Check if it exists
    existing = db.query(Remote).filter(Remote.url == url_str).first()
    if not existing:
        total = db.query(Remote).count()
        return RemoteDeleteResponse(removed=False, url=req.url, total=total)

    # Delete it
    db.delete(existing)
    db.commit()

    # Return updated total
    total = db.query(Remote).count()
    return RemoteDeleteResponse(removed=True, url=req.url, total=total)



@router.post(
    "/ingest",
    response_model=IngestResponse,
    dependencies=[Depends(require_api_token)],
)
def trigger_ingest(
    req: IngestRequest,
    db: Session = Depends(get_db),
) -> IngestResponse:
    """Trigger ingest for one or all remotes."""
    # Determine targets: single URL or all persisted remotes
    if req.url:
        targets = [str(req.url)]
    else:
        targets = [r.url for r in db.query(Remote).all()]

    if not targets:
        return IngestResponse(results=[])

    results: List[IngestItemResult] = []
    for url in targets:
        try:
            stats = _ingest_one(db, url)
            # Convert dataclass to dict for Pydantic compatibility
            if stats:
                results.append(IngestItemResult(url=url, ok=True, stats=asdict(stats)))
            else:
                results.append(IngestItemResult(url=url, ok=True, stats={}))
        except Exception as e:
            log.exception("Manual ingest failed for %s", url)
            results.append(IngestItemResult(url=url, ok=False, error=str(e)))

    # Persist all upserts and embeddings
    db.commit()

    return IngestResponse(results=results)


# --------------------------------------------------------------------------------------
# Dispatch to whatever ingest API is available
# --------------------------------------------------------------------------------------

def _ingest_one(db: Session, url: str) -> Dict[str, Any] | None:
    from ..services import ingest as ingest_mod

    candidates = [
        ("ingest_index", "kw2"),
        ("ingest_remote", "pos"),
        ("ingest", "pos"),
        ("sync_once", "pos"),
        ("sync_remote", "pos"),
    ]
    for fname, style in candidates:
        func = getattr(ingest_mod, fname, None)
        if callable(func):
            try:
                if style == "pos":
                    return func(db, url)
                if style == "kw1":
                    return func(db=db, url=url)
                if style == "kw2":
                    return func(db=db, index_url=url)
            except TypeError:
                # This block attempts different function signatures if the first fails.
                try:
                    # Try again with a different keyword argument.
                    return func(db=db, index_url=url)
                except Exception:
                    pass
                try:
                    # Try one last time with the other common keyword argument.
                    return func(db=db, url=url)
                except Exception:
                    pass
            # If all attempts within this loop fail, re-raise the last error.
            raise

    for fname in ("ingest_many", "sync_remotes", "sync_all"):
        func = getattr(ingest_mod, fname, None)
        if callable(func):
            out = func(db, [url])
            if isinstance(out, list) and out:
                first = out[0]
                return first if isinstance(first, dict) else {"result": first}
            return out if isinstance(out, dict) else {"result": out}

    raise RuntimeError("No compatible ingest function found in src.services.ingest")
