# src/routes/catalog.py

"""
Catalog routes:

- GET /catalog/search
- GET /catalog/entities/{id}
- POST /catalog/install

Wires hybrid search (lexical + vector), ranker, optional RAG, and the installer.
Returns Pydantic DTOs defined in src/schemas.py.
"""

from __future__ import annotations

import hashlib
import json
import logging
from typing import Optional, List, Dict, Any

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from fastapi.responses import RedirectResponse, JSONResponse
from sqlalchemy.orm import Session

from ..config import settings
from ..db import get_db
from ..models import Entity
from .. import schemas
from ..utils.tools import install_inline_manifest  # inline install shortcut (skip DB)

# Search plumbing (interfaces + backends)
from ..services.search import ranker, util  # type: ignore
from ..services import install  # Standard DB-backed install
# Import search backends directly from the factory singletons
from ..services.search import (  # type: ignore
    lexical_backend as lexical,
    vector_backend as vector,
    embedder,
    blobstore,
)
# Engine wrapper (adds dev/SQLite fallback when SEARCH_LEXICAL_BACKEND=none)
from ..services.search import engine

# Optional RAG and reranker (guarded)
try:  # pragma: no cover
    from ..services.search import rag  # type: ignore
except Exception:  # pragma: no cover
    rag = None  # type: ignore

try:  # pragma: no cover
    from ..services.search import reranker  # type: ignore
except Exception:  # pragma: no cover
    reranker = None  # type: ignore

router = APIRouter(prefix="/catalog")


# ----------- Helpers -----------

def _parse_filters(
    type: Optional[str],
    capabilities: Optional[str],
    frameworks: Optional[str],
    providers: Optional[str],
) -> dict:
    """CSV or None → list[str]; keep empty lists when filter not provided."""
    def _split_csv(v: Optional[str]) -> list[str]:
        if not v:
            return []
        return [x.strip() for x in v.split(",") if x.strip()]

    return {
        "type": type or "",
        "capabilities": _split_csv(capabilities),
        "frameworks": _split_csv(frameworks),
        "providers": _split_csv(providers),
    }


def _maybe_rerank(query: str, hits: List[Dict[str, Any]], algo: schemas.RerankMode) -> List[Dict[str, Any]]:
    if reranker and hasattr(reranker, "rerank"):
        try:
            return reranker.rerank(query, hits, algo=algo)  # type: ignore[attr-defined]
        except Exception:
            return hits
    return hits


def _maybe_add_fit_reasons(query: str, hits: List[Dict[str, Any]]) -> None:
    if rag and hasattr(rag, "add_fit_reasons"):  # type: ignore[attr-defined]
        try:
            rag.add_fit_reasons(query, hits, blobstore)  # type: ignore[attr-defined]
        except Exception:
            # Soft-fail; fit reasons are optional
            return


def _make_etag(key: str) -> str:
    return f'W/"{hashlib.sha256(key.encode("utf-8")).hexdigest()[:32]}"'


# ----------- Routes -----------

@router.get(
    "/search",
    response_model=schemas.SearchResponse,
    summary="Hybrid search over the catalog (lexical + vector + quality/recency)",
)
def search_catalog(
    request: Request,
    q: str = Query(..., description="User intent, e.g. 'summarize pdfs for contracts'"),
    type: Optional[str] = Query(None, description="agent|tool|mcp_server|any"),
    capabilities: Optional[str] = Query(None, description="CSV list of capability filters"),
    frameworks: Optional[str] = Query(None, description="CSV list of framework filters"),
    providers: Optional[str] = Query(None, description="CSV list of provider filters"),
    mode: schemas.SearchMode = Query(settings.SEARCH_DEFAULT_MODE.value, description="keyword|semantic|hybrid"),
    limit: int = Query(5, ge=1, le=100),  # default Top-5 (public)
    with_rag: bool = Query(False, description="Return short 'fit_reason' from top chunks"),
    with_snippets: bool = Query(False, description="Include a short summary snippet"),
    rerank_mode: schemas.RerankMode = Query(settings.RERANK_DEFAULT.value, alias="rerank", description="none|llm"),
#    include_pending: bool = Query(False, description="Include entities that are not yet registered with Gateway (dev/debug)"),
    include_pending: bool = Query(
        settings.SEARCH_INCLUDE_PENDING_DEFAULT,
        description="Include entities that are not yet registered with Gateway (dev/debug)",
    ),
    db: Session = Depends(get_db),
) -> schemas.SearchResponse:
    filters = _parse_filters(type, capabilities, frameworks, providers)

    # Treat 'any' as no type filter (public meta search behavior)
    if (filters.get("type") or "").lower() == "any":
        filters["type"] = ""

    # Enforce a Top-5 cap for the public API while still fetching a larger pool for ranking
    limit = min(limit, 5)
    POOL_K = 50

    # Common filters forwarded to backends
    base_filters = {
        "type": filters["type"] or None,
        "capabilities": filters["capabilities"],
        "frameworks": filters["frameworks"],
        "providers": filters["providers"],
        "limit": max(limit, POOL_K),
    }

    # Lexical (BM25/pg_trgm) unless semantic-only
    lex_hits: List[Dict[str, Any]] = []
    if mode != schemas.SearchMode.semantic:
        if getattr(settings, "SEARCH_LEXICAL_BACKEND", "none").lower() == "none":
            # Dev/SQLite path: engine wrapper falls back to LIKE search and respects include_pending
            lex_hits = engine.run_keyword(
                db=db,
                q=q,
                types=([filters["type"]] if filters["type"] else None),
                include_pending=include_pending,
                limit=max(limit, POOL_K),
                offset=0,
            )
        else:
            # Existing prod path (pg_trgm or other configured backend)
            lex_kwargs = dict(base_filters)
            # Forward the dev switch for backends that support it (prod-safe default False)
            lex_kwargs["include_pending"] = include_pending
            # Avoid passing db to Null backends (defensive getattr)
            if "Null" not in getattr(getattr(lexical, "__class__", object), "__name__", ""):
                lex_kwargs["db"] = db
            lex_hits = lexical.search(q, **lex_kwargs)

    # Vector (ANN) unless keyword-only — restore v0.1.4 behavior
    vec_hits: List[Dict[str, Any]] = []
    if mode != schemas.SearchMode.keyword:
        q_vec = embedder.encode([q])[0]
        vec_kwargs = dict(base_filters)
        name = getattr(getattr(vector, "__class__", object), "__name__", "")
        if "Null" in name:
            # Defensive: ensure unsupported keys are not present for Null backends
            vec_kwargs.pop("include_pending", None)
        else:
            vec_kwargs["db"] = db
        vec_hits = vector.search(q_vec, **vec_kwargs)

    # Blend + scoring
    merged = ranker.merge_and_score(lex_hits, vec_hits)

    # Optional rerank (top-50 → top-N)
    top_hits = _maybe_rerank(q, merged[: max(limit, POOL_K)], rerank_mode)[:limit]

    # Optional RAG reasons (short, cached)
    if with_rag:
        _maybe_add_fit_reasons(q, top_hits)

    items = [schemas.SearchItem(**util.serialize_hit(h, db=db, with_snippets=with_snippets)) for h in top_hits]
    total = util.estimate_total(lex_hits, vec_hits)

    # ETag + short cache (safe for public search)
    etag_key = json.dumps(
        {
            "q": q,
            "type": (filters["type"] or "any"),
            "mode": mode.value,
            "limit": limit,
            "weights": settings.SEARCH_HYBRID_WEIGHTS,
            "ids": [h.get("entity_id") for h in top_hits],
        },
        separators=(",", ":"),
        sort_keys=True,
    )
    etag = _make_etag(etag_key)

    if request.headers.get("if-none-match") == etag:
        return JSONResponse(status_code=304, content=None, headers={
            "ETag": etag,
            "Cache-Control": "public, max-age=60",
        })

    payload = schemas.SearchResponse(items=items, total=total).model_dump()
    return JSONResponse(payload, headers={
        "ETag": etag,
        "Cache-Control": "public, max-age=60",
    })


@router.get(
    "/entities/{entity_id}",
    response_model=schemas.EntityDetail,
    summary="Fetch full manifest metadata for a specific catalog entity",
)
def get_entity(
    entity_id: str,
    db: Session = Depends(get_db),
) -> schemas.EntityDetail:
    entity = db.get(Entity, entity_id)
    if not entity:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Entity not found")

    return schemas.EntityDetail(
        id=entity.uid,
        type=entity.type,
        name=entity.name,
        version=entity.version,
        summary=entity.summary,
        description=entity.description,
        capabilities=entity.capabilities or [],
        frameworks=entity.frameworks or [],
        providers=entity.providers or [],
        license=entity.license,
        homepage=entity.homepage,
        source_url=entity.source_url,
        quality_score=entity.quality_score,
        release_ts=entity.release_ts,
        readme_blob_ref=entity.readme_blob_ref,
        created_at=entity.created_at,
        updated_at=entity.updated_at,
    )


@router.post(
    "/install",
    response_model=schemas.InstallResponse,
    summary="Install an entity and optionally register it with MCP-Gateway",
)
def install_entity_route(
    req: schemas.InstallRequest,
    request: Request,
    db: Session = Depends(get_db),
) -> schemas.InstallResponse:
    """
    Execute an install plan for a catalog entity, optionally registering it
    with MCP-Gateway, and write a lockfile for reproducibility.
    """
    try:
        rid = getattr(getattr(request, "state", object()), "request_id", None)
        logging.getLogger("route.install").info(
            "install.request",
            extra={"rid": rid, "uid": req.id, "inline": bool(req.manifest), "target": req.target},
        )
        if req.manifest:
            # Inline install: bypass DB entity/source_url
            result = install_inline_manifest(
                db=db,
                uid=req.id,
                manifest=req.manifest,
                target=req.target,
                source_url=req.source_url,
            )
        else:
            # Standard catalog flow: requires prior ingest
            result = install.install_entity(
                db=db,
                entity_id=req.id,
                version=req.version,
                target=req.target,
            )

    except install.InstallError as exc:
        # Known error: translate to 422 with human-readable reason
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail={"error": "InstallError", "reason": str(exc)},
        ) from exc

    except Exception as exc:
        # Unexpected error: translate to 500
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail={"error": "InternalServerError", "reason": str(exc)},
        ) from exc

    logging.getLogger("route.install").debug(
        "install.response",
        extra={
            "rid": rid,
            "uid": req.id,
            "steps": [r.get("step") for r in (result.get("results") or [])],
        },
    )
    return schemas.InstallResponse(
        plan=result.get("plan"),
        results=result.get("results") or [],
        files_written=result.get("files_written", []),
        lockfile=result.get("lockfile"),
    )


# ----------- Optional manifest resolver (public helper) -----------
@router.get("/manifest/{entity_id}", include_in_schema=False)
def manifest_redirect(entity_id: str, db: Session = Depends(get_db)):
    e = db.get(Entity, entity_id)
    if not e or not e.source_url:
        raise HTTPException(status_code=404, detail="Manifest source URL not found")
    return RedirectResponse(url=e.source_url)
