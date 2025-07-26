"""
Configuration for Matrix Hub.

- Centralizes all environment-driven settings using pydantic-settings (Pydantic v2).
- Supports simple env overrides with safe defaults for local development.
- Exposes a singleton `settings` for the rest of the app to import.
"""

from __future__ import annotations

from enum import Enum
from typing import Dict, List, Optional, Union

from pydantic import BaseModel, Field, ValidationError, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class LexicalBackend(str, Enum):
    pgtrgm = "pgtrgm"
    opensearch = "opensearch"


class VectorBackend(str, Enum):
    pgvector = "pgvector"
    milvus = "milvus"


class BlobBackend(str, Enum):
    local = "local"
    s3 = "s3"


class TenancyMode(str, Enum):
    single = "single"
    multi = "multi"


class SearchMode(str, Enum):
    keyword = "keyword"
    semantic = "semantic"
    hybrid = "hybrid"


class RerankMode(str, Enum):
    none = "none"
    llm = "llm"


class SearchWeights(BaseModel):
    """
    Weights for hybrid ranking. Values should roughly sum to 1.0, but
    we do not enforce strict equality to keep this forgiving.
    """
    semantic: float = 0.55
    lexical: float = 0.25
    quality: float = 0.10
    recency: float = 0.10

    @field_validator("*")
    @classmethod
    def non_negative(cls, v: float) -> float:
        if v < 0:
            raise ValueError("weights must be non-negative")
        return v


class Settings(BaseSettings):
    # ---- App ----
    APP_NAME: str = "Matrix Hub"
    APP_VERSION: str = "0.1.0"
    HOST: str = "0.0.0.0"
    PORT: int = 7300
    LOG_LEVEL: str = "INFO"

    # Optional simple bearer token for admin endpoints (remotes/ingest/install, etc.)
    API_TOKEN: Optional[str] = None

    # ---- Database ----
    # Example Postgres: postgresql+psycopg://user:pass@host:5432/dbname
    # Example SQLite (dev): sqlite:///./data/catalog.sqlite
    DATABASE_URL: str = "sqlite:///./data/catalog.sqlite"
    SQL_ECHO: bool = False
    DB_POOL_SIZE: int = 10
    DB_MAX_OVERFLOW: int = 20
    DB_POOL_PRE_PING: bool = True

    # ---- CORS ----
    CORS_ALLOW_ORIGINS: List[str] = Field(default_factory=lambda: ["*"])

    # ---- Search backends (pluggable) ----
    SEARCH_BACKEND__LEXICAL: LexicalBackend = LexicalBackend.pgtrgm
    SEARCH_BACKEND__VECTOR: VectorBackend = VectorBackend.pgvector
    BLOBSTORE_BACKEND: BlobBackend = BlobBackend.local
    EMBED_MODEL_ID: str = "all-MiniLM-L12-v2"

    # ---- Search behavior ----
    SEARCH_DEFAULT_MODE: SearchMode = SearchMode.hybrid
    SEARCH_WEIGHTS: SearchWeights = Field(default_factory=SearchWeights)
    RERANK_DEFAULT: RerankMode = RerankMode.none
    RAG_ENABLED_DEFAULT: bool = False
    CACHE_TTL_SECONDS: int = 4 * 60 * 60  # 4 hours

    # ---- Ingest / Index ----
    # JSON list or comma-separated list accepted for convenience
    CATALOG_REMOTES: List[str] = Field(default_factory=list)
    INGEST_CRON: str = "*/15 * * * *"  # every 15 minutes

    # ---- Tenancy & policy ----
    TENANCY_MODE: TenancyMode = TenancyMode.single

    # ---- MCP-Gateway (optional) ----
    MCP_GATEWAY_URL: Optional[str] = None
    MCP_GATEWAY_TOKEN: Optional[str] = None

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",
    )

    # ---------- Normalizers / flexible input parsing ----------

    @field_validator("CORS_ALLOW_ORIGINS", mode="before")
    @classmethod
    def _parse_cors(cls, v: Union[str, List[str]]) -> List[str]:
        if isinstance(v, str):
            v = v.strip()
            if not v:
                return ["*"]
            if v.startswith("["):
                # JSON-ish
                try:
                    import json

                    return list(json.loads(v))
                except Exception:
                    # fall back to CSV
                    return [x.strip() for x in v.split(",") if x.strip()]
            # CSV
            return [x.strip() for x in v.split(",") if x.strip()]
        return v

    @field_validator("CATALOG_REMOTES", mode="before")
    @classmethod
    def _parse_remotes(cls, v: Union[str, List[str]]) -> List[str]:
        if isinstance(v, str):
            v = v.strip()
            if not v:
                return []
            if v.startswith("["):
                try:
                    import json

                    return list(json.loads(v))
                except Exception:
                    return [x.strip() for x in v.split(",") if x.strip()]
            return [x.strip() for x in v.split(",") if x.strip()]
        return v

    @field_validator("SEARCH_WEIGHTS", mode="before")
    @classmethod
    def _parse_weights(cls, v: Union[str, Dict[str, float], SearchWeights]) -> SearchWeights:
        if isinstance(v, SearchWeights):
            return v
        if isinstance(v, dict):
            return SearchWeights(**v)
        if isinstance(v, str):
            v = v.strip()
            if not v:
                return SearchWeights()
            # Try JSON first
            try:
                import json

                data = json.loads(v)
                return SearchWeights(**data)
            except Exception:
                # Try simple "semantic=0.55,lexical=0.25,quality=0.1,recency=0.1"
                parts = [p.strip() for p in v.split(",") if p.strip()]
                parsed: Dict[str, float] = {}
                for p in parts:
                    if "=" in p:
                        k, s_val = p.split("=", 1)
                        parsed[k.strip()] = float(s_val.strip())
                if parsed:
                    return SearchWeights(**parsed)
        # fallback
        return SearchWeights()


# Singleton settings instance
try:
    settings = Settings()  # type: ignore[call-arg]
except ValidationError as ve:
    # Fail fast with a readable error if critical env values are malformed
    # (FastAPI/Uvicorn will print this cleanly and exit)
    raise RuntimeError(f"Invalid configuration: {ve}") from ve
