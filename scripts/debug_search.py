"""
Standalone debug harness for catalog search engine.

This script lets you exercise the search engine outside of FastAPI, with
verbose logging of the SQL emitted by SQLAlchemy as well as the hit lists
returned at each stage.

Usage (run from repo root):

    uv run python debug_search.py --q "hello-sse-server" --mode keyword \
        --include-pending --limit 5 --backend none

    # or to mimic production pg_trgm backend in Postgres (if available)
    uv run python debug_search.py --q "hello-sse-server" --mode keyword \
        --include-pending --limit 5 --backend pgtrgm

The script relies on your existing SQLAlchemy models and DB settings from
src.config.settings. It will not mutate the database.
"""
from __future__ import annotations

import argparse
import logging
import os
import sys
from pathlib import Path
from typing import List, Optional

from sqlalchemy import create_engine, event, func
from sqlalchemy.orm import sessionmaker

# Ensure the package import path includes repo root
ROOT = Path(__file__).resolve().parents[0]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
if str(ROOT.parent) not in sys.path:
    sys.path.insert(0, str(ROOT.parent))

# App imports
from src.config import settings
from src.models import Entity
from src.services.search.engine import run_keyword, run_pgtrgm
from src.services.search.interfaces import Hit


# Some engine implementations may return dict-like hits when falling back.
# Normalize in printer to tolerate both dataclass objects and dicts.


def _setup_logging(verbose_sql: bool = True) -> None:
    level = logging.DEBUG
    logging.basicConfig(
        level=level,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    if verbose_sql:
        logging.getLogger("sqlalchemy.engine").setLevel(logging.INFO)
        logging.getLogger("sqlalchemy.pool").setLevel(logging.WARNING)
        logging.getLogger("sqlalchemy.dialects").setLevel(logging.WARNING)


def _make_session(db_url: Optional[str] = None):
    url = db_url or getattr(settings, "DATABASE_URL", None) or os.getenv("DATABASE_URL")
    if not url:
        # Fall back to SQLite file in repo for convenience
        url = "sqlite:///./dev.sqlite3"
    eng = create_engine(url, future=True)

    # For SQLite, enforce foreign keys, helpful when inspecting relations
    if url.startswith("sqlite"):

        @event.listens_for(eng, "connect")
        def _set_sqlite_pragma(dbapi_conn, _):  # pragma: no cover
            cursor = dbapi_conn.cursor()
            cursor.execute("PRAGMA foreign_keys=ON")
            cursor.close()

    Session = sessionmaker(bind=eng, autoflush=False, autocommit=False, future=True)
    return eng, Session


def _print_entities(rows: List[Entity]) -> None:
    for e in rows:
        print(f"  - {e.uid:40s}  [{e.type}]  {e.name} v{e.version}")


def _print_hits(label: str, hits: List[Hit]) -> None:
    print(f"\n[{label}] hits={len(hits)}")
    for h in hits:
        # Support either Hit objects or dicts
        if isinstance(h, dict):
            entity_id = h.get("entity_id")
            score = float(h.get("score", 0.0))
            source = h.get("source")
            quality = float(h.get("quality", 0.0))
            recency = float(h.get("recency", 0.0))
        else:
            entity_id = getattr(h, "entity_id", None)
            score = float(getattr(h, "score", 0.0))
            source = getattr(h, "source", None)
            quality = float(getattr(h, "quality", 0.0))
            recency = float(getattr(h, "recency", 0.0))
        try:
            print(
                f"  - {str(entity_id):40s} score={score:.3f} src={source} quality={quality:.3f} rec={recency:.3f}"
            )
        except Exception:
            print("  - hit:", h)


def main():
    parser = argparse.ArgumentParser(description="Debug catalog search engine")
    parser.add_argument("--q", required=True, help="query text (uid, slug or free-text)")
    parser.add_argument("--mode", default="keyword", choices=["keyword", "semantic", "hybrid"], help="search mode")
    parser.add_argument("--type", dest="type_filter", default=None, help="type filter: agent|tool|mcp_server|any")
    parser.add_argument("--include-pending", action="store_true", help="include unregistered entities")
    parser.add_argument("--limit", type=int, default=5)
    parser.add_argument("--offset", type=int, default=0)
    parser.add_argument("--backend", choices=["none", "pgtrgm"], default=None, help="force lexical backend")
    parser.add_argument("--db", dest="db_url", default=None, help="override DATABASE_URL")

    args = parser.parse_args()

    _setup_logging(verbose_sql=True)

    # Optionally override SEARCH_LEXICAL_BACKEND via env for this run
    if args.backend:
        os.environ["SEARCH_LEXICAL_BACKEND"] = args.backend
        # NOTE: settings is Pydantic BaseSettings and fields are read-only at runtime.
        # Use the environment variable only; engine reads it each call via settings/getattr.
        os.environ["SEARCH_LEXICAL_BACKEND"] = args.backend

    eng, Session = _make_session(args.db_url)

    print("Using DB:", eng.url)
    print("Dialect:", eng.dialect.name)
    print("Lexical backend:", os.getenv("SEARCH_LEXICAL_BACKEND", getattr(settings, "SEARCH_LEXICAL_BACKEND", "none")))

    with Session() as db:
        # Ensure we can reach the table
        # introspect count for a quick sanity check
        try:
            total_entities = db.query(Entity).count()
            print(f"Total entities in DB: {total_entities}")
        except Exception as ex:
            print("Failed to query Entity table:", ex)
            return

        types = None if (args.type_filter in (None, "", "any")) else [args.type_filter]

        # Run keyword path (this matches the route's dev/prod behavior)
        print("\n=== RUN KEYWORD ===")
        hits = run_keyword(
            db=db,
            q=args.q,
            types=types,
            include_pending=args.include_pending,
            limit=args.limit,
            offset=args.offset,
        )
        _print_hits("keyword", hits)

        # If using pgtrgm explicitly, show that path, too
        if getattr(settings, "SEARCH_LEXICAL_BACKEND", "none").lower() == "pgtrgm":
            print("\n=== RUN PGTRGM DIRECT ===")
            hits_pg = run_pgtrgm(
                db=db,
                q=args.q,
                types=types,
                include_pending=args.include_pending,
                limit=args.limit,
                offset=args.offset,
            )
            _print_hits("pgtrgm", hits_pg)

        # Show a manual UID/slug probe like engine's fallback would do
        print("\n=== PROBE UID/SLUG ===")
        qn = (args.q or "").strip().lower()
        qb = db.query(Entity)
        if ":" in qn and "@" in qn:
            qb = qb.filter(func.lower(Entity.uid) == qn)
            probe_desc = "exact uid"
        else:
            qb = qb.filter(func.lower(Entity.uid).like(f"%:{qn}@%"))
            probe_desc = "slug inside uid"
        if not args.include_pending:
            qb = qb.filter(
                Entity.gateway_registered_at.isnot(None),
                Entity.gateway_error.is_(None),
            )
        rows = qb.order_by(Entity.created_at.desc()).all()
        print(f"Probe type: {probe_desc}; rows={len(rows)}")
        _print_entities(rows)


if __name__ == "__main__":
    main()