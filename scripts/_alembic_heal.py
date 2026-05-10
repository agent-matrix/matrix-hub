#!/usr/bin/env python3
"""
Self-heal Alembic version state for both Matrix Hub (Postgres) and
MCP-Gateway (sqlite). Idempotent.

Two failure modes this script addresses:

  1) Schema is up-to-date (or partially up-to-date) but `alembic_version`
     is missing or empty. Re-running `alembic upgrade head` then crashes
     with `duplicate column` / `relation already exists`. Symptom seen on
     the gateway sqlite DB after `create_all()` was used to bootstrap.

  2) `alembic_version.version_num` points to a revision that no longer
     exists in `alembic/versions/` (e.g. an old branch's migration that
     was dropped). `alembic upgrade head` then fails with
     `Can't locate revision identified by '<rev>'`. Symptom seen on
     the Hub Postgres DB.

Action:
  * If alembic_version is missing/empty AND the DB has at least one
    non-alembic table, stamp to head.
  * If alembic_version contains a revision NOT present in the migrations
    directory, clear it and stamp to head.
  * Otherwise no-op.

Usage:
  python scripts/_alembic_heal.py --ini <path/to/alembic.ini> [--cwd DIR]

`--cwd` is the directory `alembic` should treat as project root (where
relative `script_location` and env.py live). For Matrix Hub that's the
repo root; for the gateway it's the gateway repo root.
"""
from __future__ import annotations

import argparse
import os
import sys
from contextlib import suppress


def _gather_migration_revisions(script_dir: str) -> set[str]:
    """Return the set of revision IDs declared under script_dir/versions/."""
    import re
    revs: set[str] = set()
    versions_dir = os.path.join(script_dir, "versions")
    if not os.path.isdir(versions_dir):
        return revs
    rev_re = re.compile(r"""^\s*revision(?:\s*:\s*[^=]+)?\s*=\s*['"]([^'"]+)['"]""", re.M)
    for root, _dirs, files in os.walk(versions_dir):
        for name in files:
            if not name.endswith(".py"):
                continue
            try:
                with open(os.path.join(root, name), "r", encoding="utf-8") as fh:
                    text = fh.read()
            except OSError:
                continue
            for m in rev_re.finditer(text):
                revs.add(m.group(1))
    return revs


def heal(ini_path: str, project_root: str) -> int:
    if not os.path.isfile(ini_path):
        print(f"[alembic-heal] alembic.ini not found at {ini_path}; skipping.")
        return 0

    # Capture caller's cwd; relative sqlite paths in DATABASE_URL are
    # interpreted against the caller (the same dir the app would run from),
    # not against project_root (which is where env.py lives).
    caller_cwd = os.getcwd()
    old_cwd = caller_cwd
    try:
        os.chdir(project_root)
        try:
            from alembic.config import Config
            from alembic.script import ScriptDirectory
            from sqlalchemy import create_engine, inspect, text
        except Exception as exc:
            print(f"[alembic-heal] cannot import alembic/sqlalchemy: {exc}; skipping.")
            return 0

        cfg = Config(ini_path)
        script_location = cfg.get_main_option("script_location") or "alembic"
        if not os.path.isabs(script_location):
            script_location = os.path.join(project_root, script_location)

        # Prefer DATABASE_URL from env (matches what the app's env.py uses);
        # only fall back to alembic.ini's sqlalchemy.url if it's a real URL.
        env_url = os.environ.get("DATABASE_URL", "").strip()
        ini_url = (cfg.get_main_option("sqlalchemy.url") or "").strip()

        def _is_placeholder(u: str) -> bool:
            if not u:
                return True
            # Common alembic.ini placeholders.
            if "%(" in u:
                return True
            placeholders = {
                "driver://user:pass@localhost/dbname",
                "driver://user:password@localhost/dbname",
            }
            return u in placeholders

        url = env_url if env_url else ini_url
        if _is_placeholder(url):
            url = env_url or ""
        if not url:
            print("[alembic-heal] no DB URL resolved (env DATABASE_URL empty and "
                  "alembic.ini sqlalchemy.url is a placeholder); skipping.")
            return 0

        # Special-case sqlite relative path. Try caller_cwd first, then
        # project_root, then a few common locations relative to each.
        if url.startswith("sqlite:///") and not url.startswith("sqlite:////"):
            rel = url[len("sqlite:///"):]
            candidates = [
                os.path.normpath(os.path.join(caller_cwd, rel)),
                os.path.normpath(os.path.join(project_root, rel)),
                os.path.normpath(os.path.join(os.path.dirname(project_root), rel)),
            ]
            abs_db = next((p for p in candidates if os.path.exists(p)), None)
            if abs_db is None:
                print(f"[alembic-heal] sqlite db (rel={rel!r}) not found in any of "
                      f"{candidates}; nothing to heal.")
                return 0
            url = f"sqlite:///{abs_db}"

        # Make sure alembic.command operations use the same URL we just
        # resolved (overrides whatever placeholder env.py would otherwise
        # pull from settings.database_url, which may not be initialized in
        # this preflight context).
        cfg.set_main_option("sqlalchemy.url", url)
        # Also export DATABASE_URL so any env.py that reads it picks up
        # the same value.
        os.environ["DATABASE_URL"] = url

        try:
            engine = create_engine(url)
        except Exception as exc:
            print(f"[alembic-heal] could not create engine for {url!r}: {exc}; skipping.")
            return 0

        try:
            with engine.connect() as conn:
                insp = inspect(conn)
                tables = set(insp.get_table_names())
                non_alembic = {t for t in tables if t != "alembic_version"}
                has_av = "alembic_version" in tables

                current_rev: str | None = None
                if has_av:
                    with suppress(Exception):
                        row = conn.execute(text("SELECT version_num FROM alembic_version")).fetchone()
                        if row and row[0]:
                            current_rev = str(row[0])

            # Decide if we need to stamp.
            script = ScriptDirectory.from_config(cfg)
            heads = list(script.get_heads())
            known_revs = _gather_migration_revisions(script_location)
            # Also include heads from ScriptDirectory walk (in case files exist outside our regex).
            with suppress(Exception):
                for rev in script.walk_revisions():
                    known_revs.add(rev.revision)

            need_stamp = False
            reason = ""
            if non_alembic and (not has_av or current_rev is None):
                need_stamp = True
                reason = "schema present but alembic_version is empty/missing"
            elif current_rev and current_rev not in known_revs:
                need_stamp = True
                reason = f"alembic_version={current_rev!r} not found in migrations dir"

            if not need_stamp:
                print(f"[alembic-heal] OK ({ini_path}); current={current_rev!r}, heads={heads}")
                return 0

            # When the bogus-version case is hit on Postgres, the schema
            # may be at an OLDER state than head (i.e. some intervening
            # migrations were never applied because their revision IDs
            # were on a branch that has since been deleted). Stamping
            # head blindly papers over that drift and causes
            # `UndefinedColumn` errors at query time.
            #
            # Run scripts/repair_db.py first — it adds any columns the
            # ORM expects but the DB lacks (idempotent), then it stamps
            # head itself. After it returns, alembic_version is correct
            # AND the schema actually matches head.
            #
            # If repair_db.py is missing or fails, we DELIBERATELY refuse
            # to stamp head on Postgres. Industry best practice: production
            # databases must never silently mutate alembic_version when
            # schema drift is suspected. The operator must run
            # `make repair-db` manually and re-start. SQLite (dev) keeps
            # the legacy stamp-head behavior because the cost of a wrong
            # stamp on a throwaway dev DB is zero.
            if engine.dialect.name == "postgresql":
                print(f"[alembic-heal] bogus version on Postgres ({reason}); "
                      "deferring to scripts/repair_db.py for safe schema reconciliation.")
                import subprocess
                repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
                repair = os.path.join(repo_root, "scripts", "repair_db.py")
                if os.path.isfile(repair):
                    rc = subprocess.run(
                        [sys.executable, repair],
                        env={**os.environ, "DATABASE_URL": url},
                        check=False,
                    ).returncode
                    if rc == 0:
                        print("[alembic-heal] repair_db.py succeeded; heal complete.")
                        return 0
                    print(f"[alembic-heal] ERROR: repair_db.py exited {rc}. "
                          "REFUSING to stamp head on Postgres — schema may be drifted. "
                          "Run `make repair-db` manually and inspect the output, "
                          "then restart.")
                    return 2
                print(f"[alembic-heal] ERROR: repair_db.py not found at {repair}. "
                      "REFUSING to stamp head on Postgres. Pull latest and retry.")
                return 2

            # SQLite (dev) — keep the legacy stamp-head fallback.
            print(f"[alembic-heal] stamping head ({reason}); heads={heads}")
            from alembic import command
            try:
                command.stamp(cfg, "head")
                print("[alembic-heal] stamp head succeeded.")
            except Exception as exc:
                # Last resort: directly write the head into alembic_version.
                print(f"[alembic-heal] stamp head failed: {exc!r}; trying direct write.")
                if not heads:
                    print("[alembic-heal] no heads found in migrations dir; cannot heal.")
                    return 1
                head = heads[0]
                with engine.begin() as conn:
                    if not has_av:
                        conn.execute(text(
                            "CREATE TABLE alembic_version ("
                            "version_num VARCHAR(32) NOT NULL, "
                            "CONSTRAINT alembic_version_pkc PRIMARY KEY (version_num))"
                        ))
                    conn.execute(text("DELETE FROM alembic_version"))
                    conn.execute(text("INSERT INTO alembic_version (version_num) VALUES (:v)"), {"v": head})
                print(f"[alembic-heal] direct write to alembic_version={head} succeeded.")

            return 0
        finally:
            with suppress(Exception):
                engine.dispose()
    finally:
        os.chdir(old_cwd)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ini", required=True, help="Path to alembic.ini")
    ap.add_argument("--cwd", default=None, help="Project root for env.py relative paths")
    args = ap.parse_args()
    cwd = args.cwd or os.path.dirname(os.path.abspath(args.ini)) or os.getcwd()
    try:
        return heal(args.ini, cwd)
    except Exception as exc:
        print(f"[alembic-heal] unexpected error: {exc!r}; continuing.")
        return 0


if __name__ == "__main__":
    sys.exit(main())
