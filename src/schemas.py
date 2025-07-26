"""
Pydantic DTOs and enums used by Matrix Hub API.

- Search results (items + scores)
- Entity detail view
- Install request/response payloads
"""

from __future__ import annotations

from datetime import datetime
from enum import Enum
from typing import Any, Dict, List, Optional, Union

from pydantic import BaseModel, Field


# ---------------- Enums (kept local to avoid circular imports) ----------------

class SearchMode(str, Enum):
    keyword = "keyword"
    semantic = "semantic"
    hybrid = "hybrid"


class RerankMode(str, Enum):
    none = "none"
    llm = "llm"


# ---------------- Shared types ----------------

Capabilities = List[str]
Frameworks = List[str]
Providers = List[str]
JSONDict = Dict[str, Any]
JSONValue = Union[str, int, float, bool, None, Dict[str, Any], List[Any]]


# ---------------- Search results ----------------

class SearchItem(BaseModel):
    id: str
    type: str
    name: str
    version: str
    summary: str = ""

    capabilities: Capabilities = Field(default_factory=list)
    frameworks: Frameworks = Field(default_factory=list)
    providers: Providers = Field(default_factory=list)

    score_lexical: float = 0.0
    score_semantic: float = 0.0
    score_quality: float = 0.0
    score_recency: float = 0.0
    score_final: float = 0.0

    # Populated when with_rag=true (optional short explanation)
    fit_reason: Optional[str] = None


class SearchResponse(BaseModel):
    items: List[SearchItem] = Field(default_factory=list)
    total: int


# ---------------- Entity detail ----------------

class EntityDetail(BaseModel):
    id: str
    type: str
    name: str
    version: str

    summary: Optional[str] = None
    description: Optional[str] = None

    capabilities: Capabilities = Field(default_factory=list)
    frameworks: Frameworks = Field(default_factory=list)
    providers: Providers = Field(default_factory=list)

    license: Optional[str] = None
    homepage: Optional[str] = None
    source_url: Optional[str] = None

    quality_score: float = 0.0
    release_ts: Optional[datetime] = None

    readme_blob_ref: Optional[str] = None

    created_at: datetime
    updated_at: datetime


# ---------------- Install API ----------------

class InstallRequest(BaseModel):
    id: str
    target: str
    version: Optional[str] = None


class InstallResponse(BaseModel):
    plan: Optional[JSONDict] = None
    results: Optional[Union[JSONDict, List[JSONDict]]] = None
    files_written: List[str] = Field(default_factory=list)
    lockfile: Optional[JSONDict] = None
