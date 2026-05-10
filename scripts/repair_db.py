#!/usr/bin/env python3
"""
One-shot, idempotent schema repair for the Matrix Hub catalog DB.

Why this exists
---------------
Production Aiven Postgres was previously running a migration revision
(`w7x8y9z0a1b2`) whose file has since been deleted from
`alembic/versions/`. The Alembic version pointer was stamped to the
current head (`9c4a1f7b3d2e`) by the boot self-heal — but the schema
was actually left at the state the dropped revision had produced.
That schema is missing columns/tables/indexes that the canonical
migration chain (`3df1dc689abe → 4b8f2c5d9e1a → 9c4a1f7b3d2e`) would
have created, in particular `entity.manifest_blob_ref`. Any ORM
SELECT against `Entity` (e.g. the keyword-search fallback path)
crashes with `UndefinedColumn`, surfacing as a 502.

What this script does (idempotent, safe to re-run)
--------------------------------------------------
1. CREATE EXTENSION IF NOT EXISTS pg_trgm
2. ALTER TABLE entity ADD COLUMN IF NOT EXISTS for every column the
   ORM declares but the DB lacks.
3. CREATE TABLE IF NOT EXISTS mcp_endpoint (mirrors migration
   `4b8f2c5d9e1a`).
4. CREATE INDEX IF NOT EXISTS for the GIN trigram indexes on
   entity.name / entity.summary / entity.description.
5. Stamp `alembic_version` to head (only if not already at head).
6. Print a final schema-drift report.

Usage
-----
    .venv/bin/python scripts/repair_db.py                # uses .env
    .venv/bin/python scripts/repair_db.py --dry-run      # show plan, no DDL
    .venv/bin/python scripts/repair_db.py --url <DATABASE_URL>

Exit codes: 0 success / no-op, 1 unrecoverable error.
"""

from __future__ import annotations

import argparse
import os
import sys
from contextlib import suppress

# Map of (column_name -> Postgres DDL fragment) for entity columns the
# ORM declares. This is intentionally written as raw SQL fragments so
# we don't have to import the ORM here (which would itself fail to
# import a model bound to the broken DB). Keep these aligned with
# src/models.py::Entity.
ENTITY_COLUMNS_DDL: dict[str, str] = {
    "manifest_blob_ref": "VARCHAR",
    "readme_blob_ref": "VARCHAR",
    "mcp_registration": "JSONB",
    "gateway_registered_at": "TIMESTAMP WITH TIME ZONE",
    "gateway_error": "TEXT",
    "tenant_id": "VARCHAR",
}

CREATE_MCP_ENDPOINT = """
CREATE TABLE IF NOT EXISTS mcp_endpoint (
  entity_uid VARCHAR PRIMARY KEY REFERENCES entity(uid) ON DELETE CASCADE,
  transport VARCHAR NOT NULL,
  url VARCHAR,
  command VARCHAR,
  args_json JSONB,
  env_json JSONB,
  headers_json JSONB,
  auth_json JSONB,
  discovery_json JSONB,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT ck_mcp_endpoint_transport
    CHECK (transport IN ('SSE','STDIO','WEBSOCKET','HTTP'))
);
"""

GIN_INDEXES = [
    ("ix_entity_name_trgm",        "name"),
    ("ix_entity_summary_trgm",     "summary"),
    ("ix_entity_description_trgm", "description"),
]


def _load_env_file(path: str) -> None:
    if not os.path.isfile(path):
        return
    with open(path, "r", encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                continue
            k, v = line.split("=", 1)
            k = k.strip()
            v = v.strip().strip('"').strip("'")
            os.environ.setdefault(k, v)


def _normalize_pg_url(url: str) -> str:
    if url.startswith("postgres://"):
        return "postgresql+psycopg://" + url[len("postgres://"):]
    if url.startswith("postgresql://"):
        return "postgresql+psycopg://" + url[len("postgresql://"):]
    return url


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default=None,
                    help="DATABASE_URL override; defaults to env or .env")
    ap.add_argument("--dry-run", action="store_true",
                    help="Print planned DDL but do not execute")
    args = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.path.dirname(here)
    _load_env_file(os.path.join(repo, ".env"))

    url = args.url or os.environ.get("DATABASE_URL", "").strip()
    if not url:
        print("repair_db: DATABASE_URL not set in env or .env", file=sys.stderr)
        return 1
    url = _normalize_pg_url(url)

    try:
        from sqlalchemy import create_engine, inspect, text
    except Exception as exc:
        print(f"repair_db: cannot import sqlalchemy: {exc}", file=sys.stderr)
        return 1

    engine = create_engine(url, future=True)
    if engine.dialect.name != "postgresql":
        print(f"repair_db: dialect is {engine.dialect.name}; this script only "
              "repairs Postgres DBs (sqlite dev DBs are auto-built).")
        return 0

    print(f"repair_db: connecting to {engine.url.render_as_string(hide_password=True)}")

    plan: list[tuple[str, str]] = []  # (label, sql)

    with engine.connect() as conn:
        insp = inspect(conn)
        tables = set(insp.get_table_names())
        if "entity" not in tables:
            print("repair_db: no `entity` table — DB looks empty; "
                  "let `alembic upgrade head` build it from base.")
            return 0

        existing_cols = {c["name"] for c in insp.get_columns("entity")}
        # 1. pg_trgm
        plan.append(("extension", "CREATE EXTENSION IF NOT EXISTS pg_trgm;"))

        # 2. entity columns
        for col, ddl in ENTITY_COLUMNS_DDL.items():
            if col not in existing_cols:
                plan.append((f"entity.{col}",
                             f"ALTER TABLE entity ADD COLUMN IF NOT EXISTS {col} {ddl};"))

        # 3. mcp_endpoint
        if "mcp_endpoint" not in tables:
            plan.append(("mcp_endpoint", CREATE_MCP_ENDPOINT.strip()))

        # 4. trigram indexes
        existing_indexes = {ix["name"] for ix in insp.get_indexes("entity")}
        for ix_name, col in GIN_INDEXES:
            if ix_name not in existing_indexes and col in existing_cols:
                plan.append((
                    ix_name,
                    f"CREATE INDEX IF NOT EXISTS {ix_name} "
                    f"ON entity USING gin ({col} gin_trgm_ops);",
                ))

        # 5. alembic head detection (no plan, just informational)
        head = _alembic_head(repo)
        current_av = None
        if "alembic_version" in tables:
            with suppress(Exception):
                row = conn.execute(text("SELECT version_num FROM alembic_version")).fetchone()
                if row:
                    current_av = row[0]

    if not plan and (current_av == head):
        print(f"repair_db: nothing to do (alembic_version={current_av!r}, head={head!r}).")
        return 0

    print(f"repair_db: alembic_version={current_av!r}, head={head!r}")
    print(f"repair_db: planned actions ({len(plan)}):")
    for label, _ in plan:
        print(f"  - {label}")

    if args.dry_run:
        print("repair_db: --dry-run; no DDL executed.")
        return 0

    # Execute everything in a single transaction. Postgres allows DDL
    # inside a transaction, and we want the whole repair to be atomic.
    with engine.begin() as conn:
        for label, sql in plan:
            print(f"  applying {label} ...")
            conn.execute(text(sql))

        if head and current_av != head:
            print(f"  stamping alembic_version -> {head}")
            conn.execute(text(
                "CREATE TABLE IF NOT EXISTS alembic_version ("
                "version_num VARCHAR(32) NOT NULL, "
                "CONSTRAINT alembic_version_pkc PRIMARY KEY (version_num))"
            ))
            conn.execute(text("DELETE FROM alembic_version"))
            conn.execute(text("INSERT INTO alembic_version (version_num) VALUES (:v)"),
                         {"v": head})

    # Verify
    with engine.connect() as conn:
        insp = inspect(conn)
        cols_after = {c["name"] for c in insp.get_columns("entity")}
        missing = [c for c in ENTITY_COLUMNS_DDL if c not in cols_after]
        if missing:
            print(f"repair_db: WARNING — columns still missing after repair: {missing}")
            return 1
        with suppress(Exception):
            av = conn.execute(text("SELECT version_num FROM alembic_version")).fetchone()
            print(f"repair_db: done. alembic_version={av[0] if av else None!r}")
    return 0


def _alembic_head(repo: str) -> str | None:
    versions = os.path.join(repo, "alembic", "versions")
    if not os.path.isdir(versions):
        return None
    revs: dict[str, str | None] = {}
    import re
    rev_re = re.compile(r"""^\s*revision\s*=\s*['"]([^'"]+)['"]""", re.M)
    down_re = re.compile(r"""^\s*down_revision\s*=\s*(?:['"]([^'"]+)['"]|None)""", re.M)
    for name in os.listdir(versions):
        if not name.endswith(".py") or name.startswith("__"):
            continue
        try:
            with open(os.path.join(versions, name), "r", encoding="utf-8") as fh:
                text_ = fh.read()
        except OSError:
            continue
        m = rev_re.search(text_)
        if not m:
            continue
        rev = m.group(1)
        dm = down_re.search(text_)
        down = dm.group(1) if dm and dm.group(1) else None
        revs[rev] = down
    # head = revision that no other revision points to as down_revision
    downs = {d for d in revs.values() if d}
    heads = [r for r in revs if r not in downs]
    return heads[0] if heads else None


if __name__ == "__main__":
    sys.exit(main())
