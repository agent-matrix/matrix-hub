"""
Database bootstrap for Matrix Hub.

- Builds a SQLAlchemy engine from `settings.DATABASE_URL`
- Exposes `SessionLocal` and `get_db` dependency for FastAPI routes/services
- Ensures schema is present on startup:
    * Prefer Alembic "upgrade head" if config present
    * Fallback to Base.metadata.create_all(engine) (handy for SQLite/dev)
- Provides `init_db()` with a simple health check and `close_db()` to dispose

Minor, backwards-compatible improvements in this version:
- SQLite: enable WAL + sane PRAGMAs to reduce writer/readers blocking in dev
- Postgres: apply per-request statement/lock timeouts (keeps API snappy under load)
- Optional read-only engine wiring for future search split (kept off by default)
"""

from __future__ import annotations

import logging
import os
import sqlite3
from contextlib import contextmanager
from typing import Generator, Optional

from sqlalchemy import create_engine, event, text
from sqlalchemy.engine import Engine
from sqlalchemy.exc import IntegrityError, SQLAlchemyError
from sqlalchemy.orm import Session, sessionmaker

from src.config import settings
from src.models import Entity  # ensure models module is on PYTHONPATH

log = logging.getLogger("db")

_engine: Optional[Engine] = None
_engine_ro: Optional[Engine] = None  # optional read-only engine (same as primary by default)
_schema_ready: bool = False  # ensure schema initialization runs only once

# Placeholder SessionLocal until engine is built
SessionLocal: sessionmaker[Session] = sessionmaker(class_=Session, future=True)
SessionRead: sessionmaker[Session] = sessionmaker(class_=Session, future=True)


def _build_engine(url: str) -> Engine:
    """Create a SQLAlchemy engine using project settings.

    Applies SQLite-specific connect args when needed and configures PRAGMAs on connect
    so dev instances remain responsive during writes.
    """
    connect_args: dict = {}
    if url.startswith(("sqlite://", "sqlite:///")):
        connect_args["check_same_thread"] = False

    engine_kwargs: dict = {
        "echo": settings.SQL_ECHO,
        "pool_pre_ping": settings.DB_POOL_PRE_PING,
        "connect_args": connect_args,
        "future": True,
    }
    if not url.startswith("sqlite"):
        # Only meaningful for real RDBMS drivers (e.g., Postgres)
        engine_kwargs.update(
            pool_size=getattr(settings, "DB_POOL_SIZE", 10),
            max_overflow=getattr(settings, "DB_MAX_OVERFLOW", 20),
        )

    engine = create_engine(url, **engine_kwargs)

    # SQLite: enable WAL + sane defaults so readers don't block during writes
    if url.startswith(("sqlite://", "sqlite:///")):
        @event.listens_for(engine, "connect")
        def _sqlite_pragmas(dbapi_con, _):  # pragma: no cover — connection hook
            if isinstance(dbapi_con, sqlite3.Connection):
                cur = dbapi_con.cursor()
                try:
                    cur.execute("PRAGMA journal_mode=WAL;")
                    cur.execute("PRAGMA synchronous=NORMAL;")
                    cur.execute("PRAGMA busy_timeout=30000;")  # 30s busy timeout
                    cur.execute("PRAGMA foreign_keys=ON;")
                finally:
                    cur.close()

    return engine


def _ensure_schema(engine: Engine) -> None:
    """
    Ensure the database schema exists:
      1. If an Alembic config is present, run `alembic upgrade head`
      2. Otherwise, fall back to `Base.metadata.create_all()`
    """
    global _schema_ready
    if _schema_ready:
        return

    alembic_ini = os.environ.get("ALEMBIC_INI", "alembic.ini")
    use_alembic = os.path.exists(alembic_ini)

    if use_alembic:
        try:
            from alembic import command
            from alembic.config import Config

            cfg = Config(alembic_ini)
            # Ensure Alembic uses our engine URL if not set in the ini
            if not cfg.get_main_option("sqlalchemy.url"):
                cfg.set_main_option("sqlalchemy.url", str(engine.url))

            log.info("Running Alembic migrations to head...")
            command.upgrade(cfg, "head")
            log.info("Alembic migrations applied.")
            _schema_ready = True
            return
        except Exception:
            log.exception("Alembic migration failed; falling back to create_all().")

    # Fallback for dev/SQLite: direct SQLAlchemy schema creation
    try:
        from src.models import Base  # import here to avoid circular deps at module load

        log.info("Creating tables via SQLAlchemy Base.metadata.create_all()...")
        Base.metadata.create_all(bind=engine)
        log.info("Schema ensured via create_all().")
        _schema_ready = True
    except Exception:
        log.exception("Failed to ensure schema via create_all().")
        raise


def init_db() -> None:
    """
    Initialize the global engine(s) and session factories, ensure schema,
    and perform a simple connectivity check.
    """
    global _engine, _engine_ro, SessionLocal, SessionRead

    if _engine is None:
        _engine = _build_engine(settings.DATABASE_URL)
        # Optional read-only engine: default to primary if not provided
        ro_url = getattr(settings, "DB_READ_URL", None) or settings.DATABASE_URL
        _engine_ro = _build_engine(ro_url)

        SessionLocal = sessionmaker(
            autocommit=False,
            autoflush=False,
            bind=_engine,
            future=True,
            class_=Session,
            expire_on_commit=False,  # keeps objects usable after commit in API paths
        )
        SessionRead = sessionmaker(
            autocommit=False,
            autoflush=False,
            bind=_engine_ro,
            future=True,
            class_=Session,
            expire_on_commit=False,
        )
        log.info("SQLAlchemy engines initialized.")

    # Ensure our schema is in place (only once)
    _ensure_schema(_engine)

    # Health check
    try:
        assert _engine is not None
        with _engine.connect() as conn:
            conn.execute(text("SELECT 1"))
        log.info("Database connectivity OK.")
    except SQLAlchemyError:
        log.exception("Database connectivity check failed.")
        raise


def close_db() -> None:
    """Dispose of engines and reset globals (called on app shutdown)."""
    global _engine, _engine_ro, SessionLocal, SessionRead, _schema_ready
    for eng in (_engine, _engine_ro):
        if eng is not None:
            try:
                eng.dispose()
            except Exception:  # pragma: no cover — best effort
                log.exception("Error disposing engine")
    _engine = None
    _engine_ro = None
    _schema_ready = False
    # Rebind unbound sessionmakers for import safety
    SessionLocal = sessionmaker(class_=Session, future=True)
    SessionRead = sessionmaker(class_=Session, future=True)
    log.info("SQLAlchemy engines disposed.")


def _apply_session_timeouts(db: Session) -> None:
    """Apply per-session timeouts for Postgres to keep requests snappy.

    No-ops on SQLite. Safe to call frequently.
    """
    try:
        if db.bind and db.bind.dialect.name == "postgresql":
            db.execute(text("SET LOCAL statement_timeout = '3000ms'"))
            db.execute(text("SET LOCAL lock_timeout = '1000ms'"))
            db.execute(text("SET LOCAL idle_in_transaction_session_timeout = '5000ms'"))
    except Exception:  # pragma: no cover — defensive
        log.debug("Could not apply PG timeouts on session.")


def get_db() -> Generator[Session, None, None]:
    """FastAPI dependency: yields a **write** database session and ensures cleanup."""
    if _engine is None:
        init_db()
    db = SessionLocal()
    try:
        _apply_session_timeouts(db)
        yield db
    finally:
        db.close()


def get_read_db() -> Generator[Session, None, None]:
    """Optional read-only session dependency (uses DB_READ_URL if configured).

    Keeps compatibility: routes not using this continue to use `get_db`.
    """
    if _engine is None:
        init_db()
    db = SessionRead()
    try:
        _apply_session_timeouts(db)
        yield db
    finally:
        db.close()


@contextmanager

def session_scope() -> Generator[Session, None, None]:
    """
    Context manager for standalone database sessions:

        with session_scope() as session:
            ...
    """
    if _engine is None:
        init_db()
    session = SessionLocal()
    try:
        yield session
        session.commit()
    except Exception:
        session.rollback()
        raise
    finally:
        session.close()


def save_entity(manifest: dict, session: Session) -> Entity:
    """Insert or update an Entity record based on the provided manifest dictionary.

    NOTE: This function **commits** the session. For batch ingest, prefer to call a
    non-committing variant inside a `session_scope()` and commit in batches.
    """
    uid = f"{manifest['type']}:{manifest['id']}@{manifest['version']}"
    entity = session.query(Entity).filter_by(uid=uid).first()
    if entity is None:
        entity = Entity(
            uid=uid,
            type=manifest.get("type"),
            name=manifest.get("name"),
            version=manifest.get("version"),
            # extend with additional fields as required
        )
        session.add(entity)
    else:
        # Update mutable fields
        entity.name = manifest.get("name")
        entity.version = manifest.get("version")

    try:
        session.commit()
        logging.getLogger("db").info("db.entity.commit", extra={"uid": uid})
    except IntegrityError:
        session.rollback()
        logging.getLogger("db").exception("db.entity.integrity_error", extra={"uid": uid})
        raise

    return entity
