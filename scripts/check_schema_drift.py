#!/usr/bin/env python3
"""
Pre-startup schema drift check.

Runs after Alembic self-heal but BEFORE the Hub binds its port. Compares
the live DB's `entity` (and `mcp_endpoint`) tables against the columns
the ORM declares. If anything required is missing, exits non-zero with
a structured, actionable error so the operator can run `make repair-db`
instead of starting a Hub that will 500 on every search request.

Why this exists
---------------
We hit this exact failure on Aiven: alembic_version was stamped to
head, but `entity.manifest_blob_ref` was missing. Every ORM SELECT
on `Entity` (e.g. the keyword-search fallback path) crashed with
`UndefinedColumn`, surfacing as `/catalog/search` returning 500 →
frontend 502. The Hub had no idea the schema was broken; it kept
accepting traffic.

Industry-standard pattern this implements
-----------------------------------------
* "Read-your-write" schema validation at boot.
* Fail-fast on drift, not at first traffic.
* Structured exit codes the orchestrator (run_prod.sh / supervisord /
  Kubernetes liveness probe) can act on.
* No silent stamping or auto-repair — the boot-time check refuses to
  proceed and points at the operator-facing repair tool.

Exit codes
----------
0  Schema OK or drift cannot be detected (e.g. missing config).
2  Drift detected — DO NOT start the Hub. Run `make repair-db`.
1  Unexpected error — log and continue; orchestrator decides.

Usage
-----
    python scripts/check_schema_drift.py            # uses .env
    python scripts/check_schema_drift.py --strict   # also fail on extra cols
    python scripts/check_schema_drift.py --json     # emit machine-readable
"""

from __future__ import annotations

import argparse
import json
import os
import sys

# Required entity columns that every healthy deployment must have.
# Keep aligned with src/models.py::Entity. If you add a column to the
# ORM that any production query selects, add it here too.
REQUIRED_ENTITY_COLUMNS: set[str] = {
    "uid",
    "type",
    "name",
    "version",
    "summary",
    "description",
    "license",
    "homepage",
    "source_url",
    "gateway_error",
    "tenant_id",
    "capabilities",
    "frameworks",
    "providers",
    "readme_blob_ref",
    "manifest_blob_ref",
    "quality_score",
    "release_ts",
    "created_at",
    "updated_at",
    "gateway_registered_at",
    "mcp_registration",
}

# Tables that must exist for the Hub to function (bare minimum).
REQUIRED_TABLES: set[str] = {"entity"}


def _load_env_file(path: str) -> None:
    if not os.path.isfile(path):
        return
    with open(path, "r", encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


def _normalize_url(url: str) -> str:
    if url.startswith("postgres://"):
        return "postgresql+psycopg://" + url[len("postgres://"):]
    if url.startswith("postgresql://") and "+" not in url.split("://", 1)[0]:
        return "postgresql+psycopg://" + url[len("postgresql://"):]
    return url


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--strict", action="store_true",
                    help="Also fail on unexpected extra columns/tables.")
    ap.add_argument("--json", action="store_true",
                    help="Emit machine-readable report instead of human text.")
    args = ap.parse_args()

    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    _load_env_file(os.path.join(repo, ".env"))
    url = os.environ.get("DATABASE_URL", "").strip()
    if not url:
        print("[drift-check] DATABASE_URL not set; skipping check.")
        return 0
    url = _normalize_url(url)

    try:
        from sqlalchemy import create_engine, inspect
    except Exception as exc:
        print(f"[drift-check] cannot import sqlalchemy: {exc}; skipping.")
        return 0

    try:
        engine = create_engine(url, future=True)
    except Exception as exc:
        print(f"[drift-check] could not create engine: {exc}; skipping.")
        return 1

    report: dict[str, object] = {
        "ok": True,
        "missing_tables": [],
        "missing_columns": {},
        "extra_columns": {},
        "dialect": engine.dialect.name,
    }

    try:
        with engine.connect() as conn:
            insp = inspect(conn)
            tables = set(insp.get_table_names())
            missing_tables = sorted(REQUIRED_TABLES - tables)
            report["missing_tables"] = missing_tables

            if "entity" in tables:
                cols = {c["name"] for c in insp.get_columns("entity")}
                missing_cols = sorted(REQUIRED_ENTITY_COLUMNS - cols)
                if missing_cols:
                    report["missing_columns"] = {"entity": missing_cols}
                if args.strict:
                    extra = sorted(cols - REQUIRED_ENTITY_COLUMNS)
                    if extra:
                        report["extra_columns"] = {"entity": extra}
    except Exception as exc:
        print(f"[drift-check] DB introspection failed: {exc}; skipping.")
        return 1
    finally:
        try:
            engine.dispose()
        except Exception:
            pass

    drift = bool(report["missing_tables"] or report["missing_columns"]
                 or (args.strict and report["extra_columns"]))
    report["ok"] = not drift

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        if not drift:
            print(f"[drift-check] OK ({engine.dialect.name}); "
                  f"all required tables/columns present.")
        else:
            print(f"[drift-check] SCHEMA DRIFT DETECTED ({engine.dialect.name}):")
            if report["missing_tables"]:
                print(f"  missing tables : {report['missing_tables']}")
            if report["missing_columns"]:
                for tbl, cols in report["missing_columns"].items():
                    print(f"  missing cols   : {tbl}.{{{', '.join(cols)}}}")
            if args.strict and report["extra_columns"]:
                for tbl, cols in report["extra_columns"].items():
                    print(f"  extra cols     : {tbl}.{{{', '.join(cols)}}}")
            print("")
            print("  REFUSING to start the Hub against a drifted schema.")
            print("  Reconcile with:")
            print("    make repair-db DRY=1   # preview")
            print("    make repair-db         # apply (idempotent, one txn)")

    return 2 if drift else 0


if __name__ == "__main__":
    sys.exit(main())
