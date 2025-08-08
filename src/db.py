'''
Database bootstrap for Matrix Hub.

- Builds a SQLAlchemy engine from `settings.DATABASE_URL`
- Exposes `SessionLocal` and `get_db` dependency for FastAPI routes/services
- Ensures schema is present on startup:
    * Prefer Alembic "upgrade head" if config present
    * Fallback to Base.metadata.create_all(engine) (handy for SQLite/dev)
- Provides `init_db()` with a simple health check and `close_db()` to dispose
'''

from __future__ import annotations

import logging
import os
from contextlib import contextmanager
from typing import Generator, Optional

from sqlalchemy import text, create_engine
from sqlalchemy.engine import Engine
from sqlalchemy.exc import SQLAlchemyError, IntegrityError
from sqlalchemy.orm import Session, sessionmaker

from src.config import settings
from src.models import Entity  # ensure models module is on PYTHONPATH

log = logging.getLogger("db")

_engine: Optional[Engine] = None
_schema_ready: bool = False  # ensure schema initialization runs only once

# Placeholder SessionLocal until engine is built
SessionLocal: sessionmaker[Session] = sessionmaker(class_=Session, future=True)


def _build_engine() -> Engine:
    """
    Create a SQLAlchemy engine using project settings.
    Applies SQLite-specific connect args when needed.
    """
    db_url = settings.DATABASE_URL

    connect_args: dict = {}
    if db_url.startswith("sqlite:///") or db_url.startswith("sqlite://"):
        connect_args["check_same_thread"] = False

    engine_kwargs: dict = {
        "echo": settings.SQL_ECHO,
        "pool_pre_ping": settings.DB_POOL_PRE_PING,
        "connect_args": connect_args,
        "future": True,
    }
    if not db_url.startswith("sqlite"):
        engine_kwargs.update(
            pool_size=settings.DB_POOL_SIZE,
            max_overflow=settings.DB_MAX_OVERFLOW,
        )

    return create_engine(db_url, **engine_kwargs)


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
        from src.models import Base  # import here to avoid circular dependencies at module load

        log.info("Creating tables via SQLAlchemy Base.metadata.create_all()...")
        Base.metadata.create_all(bind=engine)
        log.info("Schema ensured via create_all().")
        _schema_ready = True
    except Exception:
        log.exception("Failed to ensure schema via create_all().")
        raise


def init_db() -> None:
    """
    Initialize the global engine and session factory, ensure schema,
    and perform a simple connectivity check.
    """
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

    # Ensure our schema is in place
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
    """
    Dispose of the engine and reset globals (called on app shutdown).
    """
    global _engine, SessionLocal, _schema_ready
    if _engine is not None:
        try:
            _engine.dispose()
        finally:
            _engine = None
            _schema_ready = False
            # Rebind an unbound SessionLocal for import safety
            SessionLocal = sessionmaker(class_=Session, future=True)
            log.info("SQLAlchemy engine disposed.")


def get_db() -> Generator[Session, None, None]:
    """
    FastAPI dependency: yields a database session and ensures cleanup.
    """
    if _engine is None:
        init_db()
    db = SessionLocal()
    try:
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
    """
    Insert or update an Entity record based on the provided manifest dictionary.
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
    except IntegrityError as e:
        session.rollback()
        logging.getLogger("db").exception("db.entity.integrity_error", extra={"uid": uid})
        raise

    return entity
