# src/db.py
"""
Database bootstrap for Matrix Hub.

- Builds a SQLAlchemy engine from `settings.DATABASE_URL`
- Exposes `SessionLocal` and `get_db` dependency for FastAPI routes/services
- Ensures schema is present on startup:
    * Prefer Alembic "upgrade head" if config present
    * Fallback to Base.metadata.create_all(engine) (handy for SQLite/dev)
- Provides `init_db()` with a simple health check and `close_db()` to dispose
"""

from __future__ import annotations

import logging
import os
from contextlib import contextmanager
from typing import Generator, Optional

from sqlalchemy import text, create_engine
from sqlalchemy.engine import Engine
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session, sessionmaker

from .config import settings

log = logging.getLogger("db")

_engine: Optional[Engine] = None
_schema_ready: bool = False  # schema ensured exactly once

# IMPORTANT: Bind a dummy SessionLocal at import time so
# `from src.db import SessionLocal` never fails.
SessionLocal: sessionmaker[Session] = sessionmaker(class_=Session, future=True)


def _build_engine() -> Engine:
    db_url = settings.DATABASE_URL

    # SQLite needs special connect args; others can use defaults.
    connect_args = {}
    if db_url.startswith("sqlite:///") or db_url.startswith("sqlite://"):
        connect_args["check_same_thread"] = False

    # Build kwargs conditionally to avoid passing None for pool params.
    kwargs: dict = {
        "echo": settings.SQL_ECHO,
        "pool_pre_ping": settings.DB_POOL_PRE_PING,
        "connect_args": connect_args,
        "future": True,
    }
    if not db_url.startswith("sqlite"):
        kwargs.update(
            pool_size=settings.DB_POOL_SIZE,
            max_overflow=settings.DB_MAX_OVERFLOW,
        )

    return create_engine(db_url, **kwargs)


def _ensure_schema(engine: Engine) -> None:
    """
    Ensure DB schema exists:
      1) If Alembic is configured, run 'upgrade head'
      2) Otherwise, fallback to SQLAlchemy create_all (dev/SQLite)
    """
    global _schema_ready
    if _schema_ready:
        return

    # Prefer Alembic if present
    alembic_ini = os.environ.get("ALEMBIC_INI", "alembic.ini")
    use_alembic = os.path.exists(alembic_ini)

    if use_alembic:
        try:
            from alembic import command
            from alembic.config import Config

            cfg = Config(alembic_ini)
            # Let Alembic use the same URL as SQLAlchemy if not set in alembic.ini
            if not cfg.get_main_option("sqlalchemy.url"):
                cfg.set_main_option("sqlalchemy.url", str(engine.url))

            log.info("Running Alembic migrations to head…")
            command.upgrade(cfg, "head")
            log.info("Alembic migrations applied.")
            _schema_ready = True
            return
        except Exception:
            # Don't crash dev startup if Alembic is misconfigured; fall back
            log.exception("Alembic migration failed; falling back to create_all().")

    # Fallback: create_all for dev/SQLite
    try:
        from .models import Base  # local import to avoid circular import at module load
        log.info("Creating tables via SQLAlchemy Base.metadata.create_all()…")
        Base.metadata.create_all(bind=engine)
        log.info("Schema ensured via create_all().")
        _schema_ready = True
    except Exception:
        log.exception("Failed to ensure schema via create_all().")
        raise


def init_db() -> None:
    """Create global engine & SessionLocal, ensure schema, and run a health check."""
    global _engine, SessionLocal

    if _engine is None:
        _engine = _build_engine()
        # Recreate SessionLocal bound to the engine.
        SessionLocal = sessionmaker(
            autocommit=False,
            autoflush=False,
            bind=_engine,
            future=True,
            class_=Session,
        )
        log.info("SQLAlchemy engine initialized.")

    # Ensure schema exists (migrations/create_all)
    _ensure_schema(_engine)

    # Simple connectivity check
    try:
        assert _engine is not None
        with _engine.connect() as conn:
            conn.execute(text("SELECT 1"))
        log.info("Database connectivity OK.")
    except SQLAlchemyError:
        log.exception("Database connectivity check failed.")
        # Bubble up to stop app startup (handled by app.lifespan)
        raise


def close_db() -> None:
    """Dispose the engine and reset globals (called on app shutdown)."""
    global _engine, SessionLocal, _schema_ready
    if _engine is not None:
        try:
            _engine.dispose()
        finally:
            _engine = None
            _schema_ready = False
            # Rebind an unbound SessionLocal (import-safe)
            SessionLocal = sessionmaker(class_=Session, future=True)
            log.info("SQLAlchemy engine disposed.")


def get_db() -> Generator[Session, None, None]:
    """
    FastAPI dependency that yields a DB session and ensures cleanup.
    Usage:
        def endpoint(db: Session = Depends(get_db)): ...
    """
    if _engine is None:
        # In case someone imported get_db directly in tests without init
        init_db()
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


@contextmanager
def session_scope() -> Generator[Session, None, None]:
    """
    Context manager for non-request code paths:

        with session_scope() as db:
            ...  # commit/rollback automatically
    """
    if _engine is None:
        init_db()
    db = SessionLocal()
    try:
        yield db
        db.commit()
    except Exception:
        db.rollback()
        raise
    finally:
        db.close()
