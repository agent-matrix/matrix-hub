"""
Catalog routes:

- GET /catalog/search
- GET /catalog/entities/{id}
- POST /catalog/install

Wires hybrid search (lexical + vector), ranker, optional RAG, and the installer.
Returns Pydantic DTOs defined in src/schemas.py.
"""

from __future__ import annotations

from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session

from ..config import settings
from ..db import get_db
from ..models import Entity
from .. import schemas

# Search plumbing (interfaces + backends)
# These modules are the simple stubs/backends we outlined earlier.
from ..services.search import ranker, rag, reranker, util  # type: ignore
from ..services.search.backends import lexical, vector, embedder, blobstore  # type: ignore

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

    lex_hits = []
    vec_hits = []
    # Lexical (BM25/pg_trgm) unless semantic-only
    if mode != schemas.SearchMode.semantic:
        lex_hits = lexical.search(q=q, filters=filters, k=max(limit, 50), db=db)

    # Vector (ANN) unless keyword-only
    if mode != schemas.SearchMode.keyword:
        q_vec = embedder.encode([q])[0]
        vec_hits = vector.search(q_vector=q_vec, filters=filters, k=max(limit, 50), db=db)

    # Blend + scoring
    merged = ranker.merge_and_score(lex_hits, vec_hits)
    # Optional rerank (top-50 → top-N)
    top_hits = reranker.rerank(q, merged[: max(limit, 50)], algo=rerank_mode)[:limit]

    # Optional RAG reasons (short, cached)
    if with_rag:
        rag.add_fit_reasons(q, top_hits, blobstore)

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

    # Expect result to be a dataclass/dict with plan, results, files_written, lockfile
    return schemas.InstallResponse(
        plan=result.get("plan"),
        results=result.get("results"),
        files_written=result.get("files_written", []),
        lockfile=result.get("lockfile"),
    )
