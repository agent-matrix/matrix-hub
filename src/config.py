"""
Configuration for Matrix Hub.
- Centralizes all environment-driven settings using pydantic-settings (Pydantic v2).
- Supports simple env overrides with safe defaults for local development.
- Exposes a singleton `settings` for the rest of the app to import.
"""
from __future__ import annotations

import json
from enum import Enum
from typing import Dict, List, Optional, Union

from pydantic import (
    BaseModel,
    Field,
    ValidationError,
    field_validator,
    AliasChoices,
)
from pydantic_settings import BaseSettings, SettingsConfigDict


class LexicalBackend(str, Enum):
    pgtrgm = "pgtrgm"
    opensearch = "opensearch"
    none = "none"  # allow 'none' for local/SQLite dev


class VectorBackend(str, Enum):
    none = "none"
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
    API_TOKEN: Optional[str] = None

    # ---- Database ----
    DATABASE_URL: str = Field(
        default="sqlite+pysqlite:///./data/catalog.sqlite",
        validation_alias=AliasChoices("DATABASE_URL", "database_url"),
    )
    SQL_ECHO: bool = False
    DB_POOL_SIZE: int = 10
    DB_MAX_OVERFLOW: int = 20
    DB_POOL_PRE_PING: bool = True

    # ---- CORS ----
    CORS_ALLOW_ORIGINS: Union[List[str], str] = Field(
        default_factory=lambda: ["*"],
        validation_alias=AliasChoices(
            "CORS_ALLOW_ORIGINS", "cors_allow_origins",
        ),
    )

    # ---- Search backends ----
    SEARCH_BACKEND__LEXICAL: LexicalBackend = Field(
        default=LexicalBackend.none,
        validation_alias=AliasChoices(
            "SEARCH_BACKEND__LEXICAL", "search_backend__lexical", "SEARCH_LEXICAL_BACKEND",
        ),
    )
    SEARCH_BACKEND__VECTOR: VectorBackend = Field(
        default=VectorBackend.none,
        validation_alias=AliasChoices(
            "SEARCH_BACKEND__VECTOR", "search_backend__vector", "SEARCH_VECTOR_BACKEND",
        ),
    )
    BLOBSTORE_BACKEND: BlobBackend = Field(
        default=BlobBackend.local,
        validation_alias=AliasChoices(
            "BLOBSTORE_BACKEND", "blobstore_backend",
        ),
    )
    EMBED_MODEL_ID: str = Field(
        default="all-MiniLM-L12-v2",
        validation_alias=AliasChoices(
            "EMBED_MODEL_ID", "EMBED_MODEL", "embed_model_id", "embed_model",
        ),
    )
    BLOB_DIR: Optional[str] = Field(
        default=None,
        validation_alias=AliasChoices("BLOB_DIR", "blob_dir"),
    )

    # ---- Search behavior ----
    SEARCH_DEFAULT_MODE: SearchMode = Field(
        default=SearchMode.hybrid,
        validation_alias=AliasChoices("SEARCH_DEFAULT_MODE", "search_default_mode"),
    )
    SEARCH_WEIGHTS: Union[SearchWeights, str] = Field(
        default_factory=SearchWeights,
        validation_alias=AliasChoices("SEARCH_WEIGHTS", "search_weights"),
    )
    RERANK_DEFAULT: RerankMode = Field(
        default=RerankMode.none,
        validation_alias=AliasChoices("RERANK_DEFAULT", "rerank_default", "RERANK_MODE", "rerank_mode"),
    )
    RAG_ENABLED_DEFAULT: bool = Field(
        default=False,
        validation_alias=AliasChoices("RAG_ENABLED_DEFAULT", "rag_enabled_default", "RAG_ENABLED", "rag_enabled"),
    )
    CACHE_TTL_SECONDS: int = 4 * 60 * 60  # 4 hours

    # ---- Ingest / Index ----
    CATALOG_REMOTES: Union[List[str], str] = Field(
        default_factory=list,
        validation_alias=AliasChoices("CATALOG_REMOTES", "catalog_remotes", "MATRIX_REMOTES", "matrix_remotes"),
    )
    INGEST_INTERVAL_MIN: int = Field(
        default=15,
        validation_alias=AliasChoices("INGEST_INTERVAL_MIN", "ingest_interval_min"),
    )
    INGEST_CRON: str = Field(
        default="*/15 * * * *",
        validation_alias=AliasChoices("INGEST_CRON", "ingest_cron"),
    )

    # ---- Tenancy ----
    TENANCY_MODE: TenancyMode = Field(
        default=TenancyMode.single,
        validation_alias=AliasChoices("TENANCY_MODE", "tenancy_mode"),
    )

    # ---- MCP-Gateway ----
    MCP_GATEWAY_URL: Optional[str] = Field(
        default=None,
        validation_alias=AliasChoices("MCP_GATEWAY_URL", "mcp_gateway_url"),
    )
    MCP_GATEWAY_TOKEN: Optional[str] = Field(
        default=None,
        validation_alias=AliasChoices("MCP_GATEWAY_TOKEN", "mcp_gateway_token"),
    )

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",
    )

    INGEST_SCHED_ENABLED: bool = False  # API-safe default (scheduler off by default)


    @field_validator("CORS_ALLOW_ORIGINS", mode="before")
    @classmethod
    def _parse_cors(cls, v: Union[str, List[str]]) -> List[str]:
        if isinstance(v, str):
            v = v.strip()
            if not v:
                return ["*"]
            if v.startswith("["):
                try:
                    return list(json.loads(v))
                except Exception:
                    return [x.strip() for x in v.strip("[]").split(",") if x.strip()]
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
                    return list(json.loads(v))
                except Exception:
                    return [x.strip() for x in v.strip("[]").split(",") if x.strip()]
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
            try:
                data = json.loads(v)
                return SearchWeights(**data)
            except Exception:
                parts = [p.strip() for p in v.split(",") if p.strip()]
                parsed: Dict[str, float] = {}
                for p in parts:
                    if "=" in p:
                        k, s_val = p.split("=", 1)
                        parsed[k.strip()] = float(s_val.strip())
                if parsed:
                    return SearchWeights(**parsed)
        return SearchWeights()

    @property
    def SEARCH_LEXICAL_BACKEND(self) -> str:
        return self.SEARCH_BACKEND__LEXICAL.value

    @property
    def SEARCH_VECTOR_BACKEND(self) -> str:
        return self.SEARCH_BACKEND__VECTOR.value

    @property
    def SEARCH_HYBRID_WEIGHTS(self) -> str:
        w = self.SEARCH_WEIGHTS
        return f"sem:{w.semantic},lex:{w.lexical},q:{w.quality},rec:{w.recency}"  

    @property
    def RAG_ENABLED(self) -> bool:
        return bool(self.RAG_ENABLED_DEFAULT)

    @property
    def RERANK_MODE(self) -> str:
        return self.RERANK_DEFAULT.value

    @property
    def MATRIX_REMOTES(self) -> List[str]:
        return list(self.CATALOG_REMOTES)

    @property
    def EMBED_MODEL(self) -> str:
        return self.EMBED_MODEL_ID


# Singleton settings instance
try:
    settings = Settings()  # type: ignore[call-arg]
except ValidationError as ve:
    raise RuntimeError(f"Invalid configuration: {ve}") from ve
