from __future__ import annotations

import json
import logging
from dataclasses import asdict
from typing import Any, Dict, List, Optional, Set

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, HttpUrl, field_validator
from sqlalchemy.orm import Session

from ..config import settings
from ..db import get_db
from ..models import Remote, Entity  
from ..services.ingest import ingest_index
from ..services.install import sync_registry_gateways
from ..utils.security import require_api_token
# --------------------------------------------------------------------------------------

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
    url: HttpUrl  # Corrected from str to HttpUrl for consistency
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


# --- add these Pydantic models alongside the others in this file ---
class PendingGatewayItem(BaseModel):
    uid: str
    name: str
    version: str
    source_url: Optional[str] = None
    has_registration: bool
    server_url: Optional[str] = None
    transport: Optional[str] = None
    gateway_error: Optional[str] = None  # shows last sync error, if any

class PendingGatewaysResponse(BaseModel):
    items: List[PendingGatewayItem]
    count: int


# --- Pydantic models for delete operations ---
class PendingDeleteResponse(BaseModel):
    removed: bool
    uid: str
    reason: Optional[str] = None

class PendingBulkDeleteRequest(BaseModel):
    uids: Optional[List[str]] = None          # delete these specific UIDs
    all: Optional[bool] = False               # or set true to delete all pending
    error_only: Optional[bool] = False        # restrict to those with gateway_error

class PendingBulkDeleteResponse(BaseModel):
    removed: List[str]
    skipped: Dict[str, str]
    total_removed: int



# NOTE: The duplicate class definitions that were here have been removed.


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
            db.commit()                      # Persist ingest results immediately
            success.append(url)
        except Exception as e:
            db.rollback()                    # Undo partial work for this URL
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

# --- add this endpoint (e.g., after /remotes/sync) ---
@router.get(
    "/gateways/pending",
    response_model=PendingGatewaysResponse,
    dependencies=[Depends(require_api_token)],
)
def list_pending_gateways(
    limit: int = 100,
    offset: int = 0,
    db: Session = Depends(get_db),
) -> PendingGatewaysResponse:
    """
    List all ingested MCP servers that have NOT been registered in MCP-Gateway yet
    (Entity.type == 'mcp_server' AND gateway_registered_at IS NULL).

    Useful to verify what will be picked up by sync_registry_gateways().
    """
    q = (
        db.query(Entity)
          .filter(
              Entity.type == "mcp_server",
              Entity.gateway_registered_at.is_(None),
          )
          .order_by(Entity.created_at.desc())
    )
    rows = q.limit(max(1, min(limit, 1000))).offset(max(0, offset)).all()

    items: List[PendingGatewayItem] = []
    for ent in rows:
        reg = getattr(ent, "mcp_registration", {}) or {}
        server = reg.get("server") if isinstance(reg, dict) else {}
        url = server.get("url") if isinstance(server, dict) else None
        transport = (server.get("transport") or "").upper() if isinstance(server, dict) else None

        items.append(PendingGatewayItem(
            uid=ent.uid,
            name=ent.name,
            version=ent.version,
            source_url=ent.source_url,
            has_registration=bool(reg),
            server_url=url,
            transport=transport,
            gateway_error=getattr(ent, "gateway_error", None),
        ))

    return PendingGatewaysResponse(items=items, count=len(items))

@router.delete(
    "/gateways/pending/{uid}",
    response_model=PendingDeleteResponse,
    status_code=status.HTTP_200_OK,
    dependencies=[Depends(require_api_token)],
)
def delete_pending_gateway(uid: str, db: Session = Depends(get_db)) -> PendingDeleteResponse:
    """
    Delete a single *pending* mcp_server by UID.
    Will not delete if not found, not mcp_server, or already registered.
    """
    ent = db.get(Entity, uid)
    if not ent:
        return PendingDeleteResponse(removed=False, uid=uid, reason="not found")
    if ent.type != "mcp_server":
        return PendingDeleteResponse(removed=False, uid=uid, reason="not an mcp_server")
    if ent.gateway_registered_at is not None:
        return PendingDeleteResponse(removed=False, uid=uid, reason="already registered")

    try:
        db.delete(ent)   # embedding_chunk rows cascade via FK ondelete='CASCADE'
        db.commit()
        return PendingDeleteResponse(removed=True, uid=uid)
    except Exception as e:
        db.rollback()
        raise HTTPException(status_code=500, detail=f"Delete failed: {e}")

@router.post(
    "/gateways/pending/delete",
    response_model=PendingBulkDeleteResponse,
    status_code=status.HTTP_200_OK,
    dependencies=[Depends(require_api_token)],
)
def bulk_delete_pending_gateways(
    req: PendingBulkDeleteRequest,
    db: Session = Depends(get_db),
) -> PendingBulkDeleteResponse:
    """
    Bulk-delete pending mcp_servers.
    Provide either a list of UIDs or set all=true.
    Optionally error_only=true to delete only those with gateway_error set.
    """
    if not (req.all or (req.uids and len(req.uids) > 0)):
        raise HTTPException(status_code=400, detail="Provide uids or set all=true")

    q = (
        db.query(Entity)
          .filter(
              Entity.type == "mcp_server",
              Entity.gateway_registered_at.is_(None),
          )
    )
    if req.error_only:
        q = q.filter(Entity.gateway_error.isnot(None))
    if req.uids:
        q = q.filter(Entity.uid.in_(req.uids))

    rows = q.all()
    removed: List[str] = []
    skipped: Dict[str, str] = {}

    try:
        for ent in rows:
            db.delete(ent)
            removed.append(ent.uid)
        db.commit()
    except Exception as e:
        db.rollback()
        raise HTTPException(status_code=500, detail=f"Bulk delete failed: {e}")

    # If the caller provided specific UIDs, report any that we didn't remove and why.
    if req.uids:
        requested = set(req.uids)
        deleted = set(removed)
        for u in sorted(requested - deleted):
            ent = db.get(Entity, u)
            if ent is None:
                skipped[u] = "not found"
            elif ent.type != "mcp_server":
                skipped[u] = "not an mcp_server"
            elif ent.gateway_registered_at is not None:
                skipped[u] = "already registered"
            elif req.error_only and not ent.gateway_error:
                skipped[u] = "no gateway_error"
            else:
                skipped[u] = "not selected"

    return PendingBulkDeleteResponse(
        removed=removed,
        skipped=skipped,
        total_removed=len(removed),
    )

# --------------------------------------------------------------------------------------
# CRUD operations for remotes

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