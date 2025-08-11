"""
Pydantic DTOs and enums used by Matrix Hub API.

- Search results (items + scores)
- Entity detail view
- Install request/response payloads
"""

from __future__ import annotations

import json # <-- 1. IMPORT
from datetime import datetime
from enum import Enum
from typing import Any, Dict, List, Optional, Union

from pydantic import BaseModel, Field, field_validator # <-- 2. IMPORT field_validator


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


# ---------------- Helper for Reusable Validation ----------------

def _coerce_str_to_list(value: Any) -> List[str]:
    """Helper to robustly coerce a value into a list of strings."""
    if isinstance(value, list):
        return value
    if value is None:
        return []
    if isinstance(value, str):
        # Handle empty string
        if not value.strip():
            return []
        # Try to parse as JSON list first
        try:
            parsed = json.loads(value)
            if isinstance(parsed, list):
                return [str(item) for item in parsed]
        except json.JSONDecodeError:
            # If not valid JSON, fall back to comma-separated values
            return [item.strip() for item in value.split(',') if item.strip()]
    # As a final fallback for other types, return an empty list
    return []


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

    # --- 3. VALIDATOR ADDED ---
    @field_validator("capabilities", "frameworks", "providers", mode="before")
    @classmethod
    def _validate_lists(cls, v: Any) -> List[str]:
        return _coerce_str_to_list(v)

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

    # --- 4. SAME VALIDATOR REUSED ---
    @field_validator("capabilities", "frameworks", "providers", mode="before")
    @classmethod
    def _validate_lists(cls, v: Any) -> List[str]:
        return _coerce_str_to_list(v)

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
    """
    Request payload for installing an entity.

    Two modes of operation:
    1) DB-backed install (catalog flow): Provide a full UID or short id + version.
       The server will fetch the manifest from the DB entity's source_url.

    2) Direct/inline install (quick testing): Provide `manifest` inline. In this mode,
       no DB entity is required and the manifest is used directly.
    """
    id: str                      # e.g. "mcp_server:hello-sse-server@0.1.0"
    target: str
    version: Optional[str] = None

    # Optional inline manifest if you want to bypass DB entity/source_url
    manifest: Optional[Dict[str, Any]] = None
    # Optional: provenance for inline installs so DB + lockfile can record where it came from
    source_url: Optional[str] = None

class InstallResponse(BaseModel):
    """
    Response payload describing the installation plan and results.

    - plan: a simplified plan derived from the manifest (artifacts, adapters, mcp_registration).
    - results: list of step results (artifact installs, adapters written, gateway registration, lockfile).
    - files_written: any files created relative to the target directory (adapters, lockfile, etc.).
    - lockfile: the lockfile content describing the installed entity version and artifacts.
    """
    plan: Optional[JSONDict] = None
    results: List[JSONDict] = Field(default_factory=list)
    files_written: List[str] = Field(default_factory=list)
    lockfile: Optional[JSONDict] = None