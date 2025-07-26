"""
Database bootstrap for Matrix Hub.

- Builds a SQLAlchemy engine from `settings.DATABASE_URL`
- Exposes `SessionLocal` and `get_db` dependency for FastAPI routes/services
- Provides `init_db()` with a simple health check and `close_db()` to dispose
"""

from __future__ import annotations

import logging
from contextlib import contextmanager
from typing import Generator, Optional

from sqlalchemy import text
from sqlalchemy.engine import Engine
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy import create_engine

from .config import settings

log = logging.getLogger("db")

_engine: Optional[Engine] = None
SessionLocal: sessionmaker[Session]  # initialized in init_db()


def _build_engine() -> Engine:
    db_url = settings.DATABASE_URL

    # SQLite needs special connect args in many cases; leave others default
    connect_args = {}
    if db_url.startswith("sqlite:///") or db_url.startswith("sqlite://"):
        # For single-threaded SQLite usage in FastAPI, this relaxes thread check.
        connect_args["check_same_thread"] = False

    engine = create_engine(
        db_url,
        echo=settings.SQL_ECHO,
        pool_pre_ping=settings.DB_POOL_PRE_PING,
        pool_size=settings.DB_POOL_SIZE if not db_url.startswith("sqlite") else None,
        max_overflow=settings.DB_MAX_OVERFLOW if not db_url.startswith("sqlite") else None,
        connect_args=connect_args,
        future=True,
    )
    return engine


def init_db() -> None:
    """Create global engine & SessionLocal and run a simple health check."""
    global _engine, SessionLocal

    if _engine is None:
        _engine = _build_engine()
        SessionLocal = sessionmaker(
            autocommit=False,
            autoflush=False,
            bind=_engine,
            future=True,
            class_=Session,
        )
        log.info("SQLAlchemy engine initialized.")

    # Simple connectivity check
    try:
        with _engine.connect() as conn:  # type: ignore[union-attr]
            conn.execute(text("SELECT 1"))
        log.info("Database connectivity OK.")
    except SQLAlchemyError as exc:
        log.exception("Database connectivity check failed.")
        # Bubble up to stop app startup (handled by app.lifespan)
        raise


def close_db() -> None:
    """Dispose the engine and reset globals (called on app shutdown)."""
    global _engine, SessionLocal
    if _engine is not None:
        try:
            _engine.dispose()
        finally:
            _engine = None
            # Rebind a dummy SessionLocal to avoid NameError if imported elsewhere
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
