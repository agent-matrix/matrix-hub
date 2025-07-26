"""
Catalog remotes & ingest endpoints.

This router lets you:
- List currently configured catalog remotes (index.json URLs).
- Add/remove remotes at runtime (process-local; persisted only for the life of the process).
- Trigger an on-demand ingest against one or all remotes.

Notes
-----
* Persistence: for the MVP, remotes are kept in-process (app.state.remotes). On startup,
  this set is initialized from `settings.MATRIX_REMOTES`. You can later back this with a DB table.
* Security: write operations require a bearer token if `API_TOKEN` is set (see utils.security).
* Ingest dispatch: we call the best available function exported by `src.services.ingest`
  to stay compatible with earlier/later implementations (`ingest_index`, `ingest_remote`,
  `ingest_many`, `sync_remotes`, etc.).

Shapes
------
GET  /catalog/remotes
  -> { "items": [ { "url": "<...>" } ], "count": N }

POST /catalog/remotes
  body: { "url": "<...>" }
  -> { "added": true, "url": "<...>", "total": N }

DELETE /catalog/remotes
  query: ?url=<...>
  -> { "removed": true, "url": "<...>", "total": N }

POST /catalog/ingest
  body: { "url": "<optional single URL>" }    # if omitted => ingest all configured
  -> { "results": [ { "url": "<...>", "ok": true, "stats": {...} | "error": "..." } ] }
"""

from __future__ import annotations

import json
import logging
from typing import Any, Dict, Iterable, List, Optional, Set

from fastapi import APIRouter, Depends, HTTPException, Request, status
from pydantic import BaseModel, HttpUrl, field_validator
from sqlalchemy.orm import Session

from ..config import settings
from ..db import get_db
from ..utils.security import require_api_token

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


# --------------------------------------------------------------------------------------
# Helpers: runtime remotes store
# --------------------------------------------------------------------------------------

def _parse_initial_remotes() -> Set[str]:
    """
    Normalize settings.MATRIX_REMOTES which may be a list or a CSV/JSON string.
    """
    raw = settings.MATRIX_REMOTES
    urls: List[str] = []

    if isinstance(raw, (list, tuple)):
        urls = [str(u).strip() for u in raw if str(u).strip()]
    elif isinstance(raw, str):
        s = raw.strip()
        if not s:
            urls = []
        else:
            # Try JSON array first
            try:
                arr = json.loads(s)
                if isinstance(arr, list):
                    urls = [str(u).strip() for u in arr if str(u).strip()]
                else:
                    urls = [s]
            except Exception:
                # fallback: CSV
                urls = [u.strip() for u in s.split(",") if u.strip()]
    else:
        urls = []

    # De-dup while preserving order
    seen: Set[str] = set()
    out: List[str] = []
    for u in urls:
        if u not in seen:
            seen.add(u)
            out.append(u)
    return set(out)


def _get_runtime_remotes(request: Request) -> Set[str]:
    """
    Return the process-local set of remotes, initializing from settings on first use.
    """
    if not hasattr(request.app.state, "remotes") or request.app.state.remotes is None:
        request.app.state.remotes = _parse_initial_remotes()
        log.info("Initialized remotes from settings: %s", sorted(request.app.state.remotes))
    return request.app.state.remotes


# --------------------------------------------------------------------------------------
# Endpoints
# --------------------------------------------------------------------------------------

@router.get("/remotes", response_model=RemoteListResponse)
def list_remotes(request: Request) -> RemoteListResponse:
    remotes = sorted(_get_runtime_remotes(request))
    return RemoteListResponse(items=[RemoteItem(url=u) for u in remotes], count=len(remotes))


@router.post(
    "/remotes",
    response_model=RemoteCreateResponse,
    status_code=status.HTTP_201_CREATED,
    dependencies=[Depends(require_api_token)],
)
def add_remote(req: RemoteCreateRequest, request: Request) -> RemoteCreateResponse:
    remotes = _get_runtime_remotes(request)
    added = False
    if str(req.url) not in remotes:
        remotes.add(str(req.url))
        added = True
        log.info("Remote added: %s", req.url)
    else:
        log.info("Remote already present: %s", req.url)
    return RemoteCreateResponse(added=added, url=req.url, total=len(remotes))


@router.delete(
    "/remotes",
    response_model=RemoteDeleteResponse,
    dependencies=[Depends(require_api_token)],
)
def delete_remote(url: str, request: Request) -> RemoteDeleteResponse:
    if not url:
        raise HTTPException(status_code=400, detail="Query parameter 'url' is required.")
    remotes = _get_runtime_remotes(request)
    removed = url in remotes
    if removed:
        remotes.remove(url)
        log.info("Remote removed: %s", url)
    return RemoteDeleteResponse(removed=removed, url=url, total=len(remotes))


@router.post(
    "/ingest",
    response_model=IngestResponse,
    dependencies=[Depends(require_api_token)],
)
def trigger_ingest(req: IngestRequest, request: Request, db: Session = Depends(get_db)) -> IngestResponse:
    """
    Trigger a manual ingest. If a URL is provided -> ingest only that remote.
    Otherwise, ingest all configured remotes.
    """
    # Decide target URLs
    if req.url:
        targets = [str(req.url)]
    else:
        targets = sorted(_get_runtime_remotes(request))
        if not targets:
            # If no remotes configured, accept the call but do nothing
            return IngestResponse(results=[])

    results: List[IngestItemResult] = []
    for url in targets:
        try:
            stats = _ingest_one(db, url)
            results.append(IngestItemResult(url=url, ok=True, stats=stats or {}))
        except Exception as e:
            log.exception("Manual ingest failed for %s", url)
            results.append(IngestItemResult(url=url, ok=False, error=str(e)))

    return IngestResponse(results=results)


# --------------------------------------------------------------------------------------
# Dispatch to whatever ingest API is available (compatibility layer)
# --------------------------------------------------------------------------------------

def _ingest_one(db, url: str) -> Dict[str, Any] | None:
    """
    Call the best-matching function from src.services.ingest, handling several
    possible historical names/signatures.
    """
    from ..services import ingest as ingest_mod  # local import to keep router import-light

    # Candidates: (func_name, call_style)
    # call_style:
    #   "pos"  -> func(db, url)
    #   "kw1"  -> func(db=db, url=url)
    #   "kw2"  -> func(db=db, index_url=url)
    candidates = [
        ("ingest_index", "kw2"),
        ("ingest_remote", "pos"),
        ("ingest", "pos"),
        ("sync_once", "pos"),    # (db, url) single
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
                # Try alternative keyword signatures transparently
                try:
                    return func(db=db, index_url=url)  # type: ignore
                except Exception:
                    pass
                try:
                    return func(db=db, url=url)  # type: ignore
                except Exception:
                    pass
            # Any other exception should bubble to the caller to be reported per-URL
            raise

    # Multi-target function as fallback (e.g., sync_remotes(db, [urls]))
    for fname in ("ingest_many", "sync_remotes", "sync_all"):
        func = getattr(ingest_mod, fname, None)
        if callable(func):
            out = func(db, [url])  # type: ignore
            # Normalize to first result if a list is returned
            if isinstance(out, list) and out:
                first = out[0]
                return first if isinstance(first, dict) else {"result": first}
            return out if isinstance(out, dict) else {"result": out}

    raise RuntimeError("No compatible ingest function found in src.services.ingest")


# --------------------------------------------------------------------------------------
# End
# --------------------------------------------------------------------------------------
