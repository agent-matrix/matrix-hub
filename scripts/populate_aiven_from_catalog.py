#!/usr/bin/env python3
"""
scripts/populate_aiven_from_catalog.py

Populate matrix-hub's `entity` table directly from
https://github.com/agent-matrix/catalog without going through the Hub.

Usage
-----
    AIVEN_URL='postgresql://avnadmin:PW@HOST:PORT/defaultdb?sslmode=require' \
      python3 scripts/populate_aiven_from_catalog.py

    # Or read from .env (DATABASE_URL_PRIMARY by default):
    python3 scripts/populate_aiven_from_catalog.py

Knobs
-----
    AIVEN_URL                  full libpq/SQLAlchemy URL  (preferred)
    DATABASE_URL_PRIMARY       same, picked up if AIVEN_URL absent
    DATABASE_URL               final fallback
    CATALOG_INDEX_URL          default agent-matrix/catalog index
    CATALOG_RAW_BASE           default agent-matrix/catalog raw base
    INCLUDE_STATUSES           comma list, default "active"  (try "active,deprecated")
    LIMIT                      cap items processed (default 0 = no cap)
    WORKERS                    parallel manifest fetchers (default 16)
    DRY_RUN=1                  fetch + transform but do not write to DB
    QUIET=1                    only print summary + errors

Credentials policy
------------------
Never embeds secrets. Reads them from env or .env. Refuses to print the
password in any URL.
"""
from __future__ import annotations

import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from pathlib import Path
from typing import Any

INDEX_URL = os.environ.get(
    "CATALOG_INDEX_URL",
    "https://raw.githubusercontent.com/agent-matrix/catalog/main/index.json",
)
RAW_BASE = os.environ.get(
    "CATALOG_RAW_BASE",
    "https://raw.githubusercontent.com/agent-matrix/catalog/main/",
).rstrip("/") + "/"
INCLUDE = {s.strip() for s in os.environ.get("INCLUDE_STATUSES", "active").split(",") if s.strip()}
LIMIT = int(os.environ.get("LIMIT", "0") or "0")
WORKERS = int(os.environ.get("WORKERS", "16") or "16")
DRY_RUN = os.environ.get("DRY_RUN", "0") == "1"
QUIET = os.environ.get("QUIET", "0") == "1"
ENV_FILE = os.environ.get("ENV_FILE", ".env")
URL_VAR = os.environ.get("URL_VAR", "DATABASE_URL_PRIMARY")


def _color(code, s): return f"\033[{code}m{s}\033[0m" if sys.stderr.isatty() else s
def info(m):  not QUIET and print(f"  {m}", file=sys.stderr)
def ok(m):    not QUIET and print(f"  {_color('32','✓')} {m}", file=sys.stderr)
def warn(m):  print(f"  {_color('33','!')} {m}", file=sys.stderr)
def bad(m):   print(f"  {_color('31','✗')} {m}", file=sys.stderr)
def step(m):
    if not QUIET:
        print(f"\n\033[1m▶ {m}\033[0m", file=sys.stderr)
        print("-" * 72, file=sys.stderr)


def mask_url(u: str) -> str:
    return re.sub(r"(://[^:]+:)[^@]+(@)", r"\1***\2", u)


def resolve_url() -> str:
    for k in ("AIVEN_URL", URL_VAR, "DATABASE_URL"):
        v = os.environ.get(k)
        if v:
            info(f"using credential from env: {k}")
            return v
    p = Path(ENV_FILE)
    if p.is_file():
        for line in p.read_text(errors="ignore").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, _, v = line.partition("=")
            if k.strip() in {URL_VAR, "AIVEN_URL", "DATABASE_URL"} and v:
                info(f"using credential from {ENV_FILE}: {k}")
                return v.strip().strip('"').strip("'")
    bad(f"no DB URL found. Set AIVEN_URL or {URL_VAR} in env or {ENV_FILE}.")
    sys.exit(1)


def to_libpq(u: str) -> str:
    u = re.sub(r"^postgresql\+(psycopg|asyncpg)://", "postgresql://", u)
    u = re.sub(r"^postgres://", "postgresql://", u)
    return u


def http_get_json(url: str, timeout: int = 30) -> Any:
    req = urllib.request.Request(url, headers={"User-Agent": "matrix-hub-populator/1.0"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def transform(item: dict, manifest: dict) -> dict | None:
    try:
        uid = item["id"]
        if "@" not in uid and item.get("version"):
            uid = f"{item['id']}@{item['version']}"
        etype = item.get("type") or manifest.get("type") or "mcp_server"
        if etype not in ("agent", "tool", "mcp_server"):
            return None

        name = manifest.get("title") or item.get("name") or item["id"]
        version = item.get("version") or manifest.get("version") or "0.0.0"
        summary = manifest.get("title")
        description = manifest.get("description")

        links = manifest.get("links") or {}
        license_ = links.get("license") or manifest.get("license")
        homepage = links.get("homepage") or manifest.get("homepage")
        source_url = links.get("source") or links.get("repository") or manifest.get("source_url")

        capabilities = manifest.get("capabilities") or []
        frameworks = manifest.get("frameworks") or []
        providers = manifest.get("providers") or []

        mcp_reg = manifest.get("mcp_registration") or {}
        if not mcp_reg and manifest.get("remotes"):
            mcp_reg = {"server": {"remotes": manifest["remotes"]}}

        release_ts_raw = (manifest.get("provenance") or {}).get("published_at")
        try:
            release_ts = (
                datetime.fromisoformat(release_ts_raw.replace("Z", "+00:00"))
                if release_ts_raw else None
            )
        except Exception:
            release_ts = None

        return dict(
            uid=uid,
            type=etype,
            name=name[:200],
            version=str(version)[:64],
            summary=(summary or "")[:1024] or None,
            description=description,
            license=license_,
            homepage=homepage,
            source_url=source_url,
            tenant_id="public",
            capabilities=json.dumps(capabilities),
            frameworks=json.dumps(frameworks),
            providers=json.dumps(providers),
            quality_score=0.0,
            release_ts=release_ts,
            mcp_registration=json.dumps(mcp_reg) if mcp_reg else None,
        )
    except Exception as e:
        warn(f"transform failed for {item.get('id')!r}: {e}")
        return None


def main() -> int:
    step("0. Preflight")
    try:
        import psycopg
    except ImportError:
        bad("psycopg not installed. Install with:  pip install 'psycopg[binary]'")
        return 1

    if DRY_RUN:
        info("DRY_RUN=1 — no DB writes will be performed")

    raw_url = resolve_url()
    libpq_url = to_libpq(raw_url)
    ok(f"target: {mask_url(libpq_url)}")

    step("1. Fetch catalog index")
    info(f"GET {INDEX_URL}")
    t0 = time.monotonic()
    idx = http_get_json(INDEX_URL, timeout=60)
    items = idx.get("items", [])
    counts = idx.get("counts", {})
    ok(f"index loaded in {time.monotonic() - t0:.1f}s — {counts}")

    selected = [it for it in items if it.get("status", "active") in INCLUDE]
    if LIMIT > 0:
        selected = selected[:LIMIT]
    ok(f"selected {len(selected)} items (statuses {sorted(INCLUDE)})")
    if not selected:
        warn("nothing to do — exiting")
        return 0

    step("2. Open DB")
    if not DRY_RUN:
        try:
            conn = psycopg.connect(libpq_url, connect_timeout=15)
            conn.autocommit = False
        except Exception as e:
            bad(f"could not connect: {e}")
            return 1
        ok("connected")
    else:
        conn = None

    step(f"3. Fetch manifests + UPSERT (workers={WORKERS})")
    UPSERT_SQL = """
INSERT INTO entity (
  uid, type, name, version, summary, description,
  license, homepage, source_url, tenant_id,
  capabilities, frameworks, providers,
  quality_score, release_ts, mcp_registration
)
VALUES (
  %(uid)s, %(type)s, %(name)s, %(version)s, %(summary)s, %(description)s,
  %(license)s, %(homepage)s, %(source_url)s, %(tenant_id)s,
  %(capabilities)s::jsonb, %(frameworks)s::jsonb, %(providers)s::jsonb,
  %(quality_score)s, %(release_ts)s, %(mcp_registration)s::jsonb
)
ON CONFLICT (uid) DO UPDATE SET
  type             = EXCLUDED.type,
  name             = EXCLUDED.name,
  version          = EXCLUDED.version,
  summary          = EXCLUDED.summary,
  description      = EXCLUDED.description,
  license          = EXCLUDED.license,
  homepage         = EXCLUDED.homepage,
  source_url       = EXCLUDED.source_url,
  capabilities     = EXCLUDED.capabilities,
  frameworks       = EXCLUDED.frameworks,
  providers        = EXCLUDED.providers,
  release_ts       = EXCLUDED.release_ts,
  mcp_registration = EXCLUDED.mcp_registration;
"""

    inserts = updates = skipped = errors = 0
    started = time.monotonic()

    def fetch_one(it):
        path = it.get("manifest_path")
        if not path:
            return it, None, "no manifest_path"
        url = urllib.parse.urljoin(RAW_BASE, path)
        try:
            return it, http_get_json(url, timeout=30), None
        except Exception as e:
            return it, None, f"{type(e).__name__}: {e}"

    BATCH = 200
    pending: list[dict] = []

    def flush():
        nonlocal inserts, updates, errors
        if not pending or DRY_RUN:
            pending.clear()
            return
        try:
            with conn.cursor() as cur:
                uids = [r["uid"] for r in pending]
                cur.execute("SELECT uid FROM entity WHERE uid = ANY(%s);", (uids,))
                existing = {row[0] for row in cur.fetchall()}
                cur.executemany(UPSERT_SQL, pending)
            conn.commit()
            inserts += sum(1 for r in pending if r["uid"] not in existing)
            updates += sum(1 for r in pending if r["uid"] in existing)
        except Exception as e:
            conn.rollback()
            errors += len(pending)
            bad(f"batch UPSERT failed ({len(pending)} rows): {e}")
        finally:
            pending.clear()

    with ThreadPoolExecutor(max_workers=WORKERS) as pool:
        futures = [pool.submit(fetch_one, it) for it in selected]
        done = 0
        for fut in as_completed(futures):
            it, manifest, err = fut.result()
            done += 1
            if err:
                skipped += 1
                if not QUIET and skipped <= 5:
                    warn(f"fetch failed {it.get('id')}: {err}")
            elif manifest is None:
                skipped += 1
            else:
                row = transform(it, manifest)
                if row is None:
                    skipped += 1
                else:
                    pending.append(row)
                    if len(pending) >= BATCH:
                        flush()
            if done % 500 == 0:
                rate = done / (time.monotonic() - started)
                info(f"  progress: {done}/{len(selected)}  rate={rate:.0f}/s  inserts={inserts}  updates={updates}  skipped={skipped}  errors={errors}")

    flush()

    step("4. Sanity")
    if not DRY_RUN:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT 'entity='||(SELECT count(*) FROM entity)"
                "||', remote='||(SELECT count(*) FROM remote)"
                "||', embedding_chunk='||(SELECT count(*) FROM embedding_chunk);"
            )
            ok(f"row counts: {cur.fetchone()[0]}")
            cur.execute("SELECT type, count(*) FROM entity GROUP BY type ORDER BY 2 DESC;")
            for t, n in cur.fetchall():
                info(f"  {t}: {n}")
        conn.close()

    step("Summary")
    duration = time.monotonic() - started
    print(
        f"  selected = {len(selected)}\n"
        f"  inserts  = {inserts}\n"
        f"  updates  = {updates}\n"
        f"  skipped  = {skipped}\n"
        f"  errors   = {errors}\n"
        f"  duration = {duration:.1f}s",
        file=sys.stderr,
    )
    return 0 if errors == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
