"""
Catalog routes:

- GET /catalog/search
- GET /catalog/entities/{id}
- POST /catalog/install

Wires hybrid search (lexical + vector), ranker, optional RAG, and the installer.
Returns Pydantic DTOs defined in src/schemas.py.
"""

from __future__ import annotations

from typing import Optional, List, Dict, Any

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session

from ..config import settings
from ..db import get_db
from ..models import Entity
from .. import schemas

# Search plumbing (interfaces + backends)
from ..services.search import ranker, util  # type: ignore

# Import search backends directly from the factory singletons
from ..services.search import (  # type: ignore
    lexical_backend as lexical,
    vector_backend as vector,
    embedder,
    blobstore,
)

# Optional RAG and reranker (guarded)
try:  # pragma: no cover
    from ..services.search import rag  # type: ignore
except Exception:  # pragma: no cover
    rag = None  # type: ignore

try:  # pragma: no cover
    from ..services.search import reranker  # type: ignore
except Exception:  # pragma: no cover
    reranker = None  # type: ignore

# Installer service
from ..services import install  # type: ignore


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


# ----------- Routes -----------

@router.get(
    "/search",
    response_model=schemas.SearchResponse,
    summary="Hybrid search over the catalog (lexical + vector + quality/recency)",
)
def search_catalog(
    q: str = Query(..., description="User intent, e.g. 'summarize pdfs for contracts'"),
    type: Optional[str] = Query(None, description="agent|tool|mcp_server"),
    capabilities: Optional[str] = Query(None, description="CSV list of capability filters"),
    frameworks: Optional[str] = Query(None, description="CSV list of framework filters"),
    providers: Optional[str] = Query(None, description="CSV list of provider filters"),
    mode: schemas.SearchMode = Query(settings.SEARCH_DEFAULT_MODE.value, description="keyword|semantic|hybrid"),
    limit: int = Query(20, ge=1, le=100),
    with_rag: bool = Query(False, description="Return short 'fit_reason' from top chunks"),
    rerank_mode: schemas.RerankMode = Query(settings.RERANK_DEFAULT.value, alias="rerank", description="none|llm"),
    db: Session = Depends(get_db),
) -> schemas.SearchResponse:
    filters = _parse_filters(type, capabilities, frameworks, providers)

    # Lexical (BM25/pg_trgm) unless semantic-only
    lex_hits: List[Dict[str, Any]] = []
    if mode != schemas.SearchMode.semantic:
        # ❗️ FIXED: Conditionally pass `db` to avoid TypeError with Null backends in tests.
        lex_kwargs = {
            "type": filters["type"] or None,
            "capabilities": filters["capabilities"],
            "frameworks": filters["frameworks"],
            "providers": filters["providers"],
            "limit": max(limit, 50),
        }
        if "Null" not in lexical.__class__.__name__:
            lex_kwargs["db"] = db
        lex_hits = lexical.search(q, **lex_kwargs)

    # Vector (ANN) unless keyword-only
    vec_hits: List[Dict[str, Any]] = []
    if mode != schemas.SearchMode.keyword:
        q_vec = embedder.encode([q])[0]
        # ❗️ FIXED: Conditionally pass `db` to avoid TypeError with Null backends in tests.
        vec_kwargs = {
            "type": filters["type"] or None,
            "capabilities": filters["capabilities"],
            "frameworks": filters["frameworks"],
            "providers": filters["providers"],
            "limit": max(limit, 50),
        }
        if "Null" not in vector.__class__.__name__:
            vec_kwargs["db"] = db
        vec_hits = vector.search(q_vec, **vec_kwargs)

    # Blend + scoring
    merged = ranker.merge_and_score(lex_hits, vec_hits)

    # Optional rerank (top-50 → top-N)
    top_hits = _maybe_rerank(q, merged[: max(limit, 50)], rerank_mode)[:limit]

    # Optional RAG reasons (short, cached)
    if with_rag:
        _maybe_add_fit_reasons(q, top_hits)

    # Serialize to DTOs; util.serialize_hit can attach entity fields if needed
    items = [schemas.SearchItem(**util.serialize_hit(h, db=db)) for h in top_hits]
    total = util.estimate_total(lex_hits, vec_hits)

    return schemas.SearchResponse(items=items, total=total)


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
    summary="Install an entity and optionally register it in MCP-Gateway",
)
def install_entity(
    req: schemas.InstallRequest,
    db: Session = Depends(get_db),
) -> schemas.InstallResponse:
    """
    Executes the entity's install plan (pip/uv, docker, git, etc.),
    writes adapters into the target project, and returns a lockfile entry.
    """
    try:
        result = install.install_entity(
            db=db,
            entity_id=req.id,
            version=req.version,
            target=req.target,
        )
    except install.InstallError as exc:  # type: ignore[attr-defined]
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail={"error": "InstallError", "reason": str(exc)},
        ) from exc

    # Expect result to be a dict with plan, results, files_written, lockfile
    return schemas.InstallResponse(
        plan=result.get("plan"),
        results=result.get("results"),
        files_written=result.get("files_written", []),
        lockfile=result.get("lockfile"),
    )
