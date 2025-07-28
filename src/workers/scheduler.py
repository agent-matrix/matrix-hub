"""
Background scheduler for periodic catalog ingestion.

- Uses APScheduler BackgroundScheduler (in‑process, cooperative).
- Reads remote index URLs from:
    * app.state.remotes  (mutable at runtime via /catalog/remotes)
    * settings.MATRIX_REMOTES (fallback)
- Interval (minutes) comes from settings.INGEST_INTERVAL_MIN.
- Safe no‑op if interval <= 0 or APScheduler is unavailable.

Design notes
------------
* We keep the scheduler reference on `app.state.scheduler`.
* Only one job instance runs at a time (coalesce=True, max_instances=1).
* A small jitter is applied to avoid thundering herd in multi‑instance deploys.
* First run is scheduled shortly after startup.
"""

from __future__ import annotations

import json
import logging
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List

from fastapi import FastAPI

from ..config import settings
from ..db import SessionLocal

log = logging.getLogger(__name__)

try:
    from apscheduler.schedulers.background import BackgroundScheduler  # type: ignore
    from apscheduler.triggers.interval import IntervalTrigger  # type: ignore

    _HAS_APSCHEDULER = True
except Exception:  # pragma: no cover
    BackgroundScheduler = None  # type: ignore
    IntervalTrigger = None  # type: ignore
    _HAS_APSCHEDULER = False


# --------------------------------------------------------------------------------------
# Public API
# --------------------------------------------------------------------------------------

def start_scheduler(app: FastAPI) -> None:
    """
    Start the background scheduler with the ingest job if enabled and available.

    Safe to call multiple times; subsequent calls are ignored if a scheduler
    is already present on `app.state.scheduler`.
    """
    if not _HAS_APSCHEDULER:
        log.warning("APScheduler not available; background ingestion disabled.")
        return

    interval_min = int(settings.INGEST_INTERVAL_MIN or 0)
    if interval_min <= 0:
        log.info("Ingestion scheduler disabled (INGEST_INTERVAL_MIN=%s).", interval_min)
        return

    if getattr(app.state, "scheduler", None):
        # Already running (e.g., hot reload or duplicate init)
        log.debug("Scheduler already present; skipping start.")
        return

    # Configure the background scheduler
    scheduler = BackgroundScheduler(
        timezone=timezone.utc,
        job_defaults={
            "coalesce": True,        # if delayed, run once for skipped intervals
            "max_instances": 1,      # avoid overlapping runs
            "misfire_grace_time": 120,
        },
    )

    # Define job wrapper capturing the `app` instance
    def _ingest_job() -> None:
        try:
            _run_ingest_cycle(app)
        except Exception:
            log.exception("Unhandled error during scheduled ingest cycle.")

    # Interval trigger with a small jitter to spread load
    trigger = IntervalTrigger(minutes=interval_min, jitter=30, timezone=timezone.utc)

    # Schedule first run ~15 seconds after startup (tunable)
    next_at = datetime.now(tz=timezone.utc) + timedelta(seconds=15)

    scheduler.add_job(
        _ingest_job,
        trigger=trigger,
        id="catalog-ingest",
        name="Matrix Hub — catalog ingest",
        replace_existing=True,
        next_run_time=next_at,
    )

    scheduler.start()
    app.state.scheduler = scheduler
    log.info(
        "Ingestion scheduler started: every %s min (first run at %s).",
        interval_min,
        next_at.isoformat(),
    )

    # Ensure a clean shutdown
    def _on_shutdown() -> None:
        stop_scheduler(app)

    try:
        app.add_event_handler("shutdown", _on_shutdown)
    except Exception:
        # If the app does not support dynamic event handlers, ignore.
        pass


def stop_scheduler(app: FastAPI) -> None:
    """
    Stop the scheduler if present.
    """
    sched = getattr(app.state, "scheduler", None)
    if not sched:
        return
    try:
        sched.shutdown(wait=False)
        log.info("Ingestion scheduler stopped.")
    except Exception:
        log.exception("Failed to stop scheduler cleanly.")
    finally:
        app.state.scheduler = None


# --------------------------------------------------------------------------------------
# Core cycle
# --------------------------------------------------------------------------------------

def _run_ingest_cycle(app: FastAPI) -> None:
    """
    One ingest pass over all configured remotes.
    Uses a dedicated DB session and releases it at the end.
    """
    urls = _current_remotes(app)
    if not urls:
        log.debug("No remotes configured; skipping ingest cycle.")
    return

    log.info("Ingest cycle starting for %d remote(s).", len(urls))
    ok_count = 0
    err_count = 0

    db = SessionLocal()
    try:
        for url in urls:
            try:
                stats = _ingest_one(db, url)
                ok_count += 1
                # Keep logs compact but useful
                if isinstance(stats, dict) and stats:
                    log.info("Ingest OK: %s stats=%s", url, _compact(stats))
                else:
                    log.info("Ingest OK: %s", url)
            except Exception as e:
                err_count += 1
                log.exception("Ingest failed for %s: %s", url, e)
        log.info("Ingest cycle complete: ok=%d, errors=%d.", ok_count, err_count)
    finally:
        try:
            db.close()
        except Exception:
            pass


# --------------------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------------------

def _current_remotes(app: FastAPI) -> List[str]:
    """
    Prefer process‑local runtime set (mutated by /catalog/remotes). Fall back to settings.
    """
    urls: List[str] = []
    state_remotes = getattr(app.state, "remotes", None)
    if isinstance(state_remotes, (set, list, tuple)):
        urls = [str(u).strip() for u in state_remotes if str(u).strip()]
    else:
        urls = _parse_remotes(settings.MATRIX_REMOTES)
    # De‑dup while preserving order
    seen = set()
    out: List[str] = []
    for u in urls:
        if u not in seen:
            seen.add(u)
            out.append(u)
    return out


def _parse_remotes(raw: Any) -> List[str]:
    """
    Accepts list/tuple, JSON string (array), or CSV string; returns list[str].
    """
    if isinstance(raw, (list, tuple)):
        return [str(u).strip() for u in raw if str(u).strip()]
    if isinstance(raw, str):
        s = raw.strip()
        if not s:
            return []
        try:
            arr = json.loads(s)
            if isinstance(arr, list):
                return [str(u).strip() for u in arr if str(u).strip()]
        except Exception:
            # fallback CSV
            return [u.strip() for u in s.split(",") if u.strip()]
    return []


def _ingest_one(db, url: str) -> Dict[str, Any] | None:
    """
    Dispatch to whichever ingest function is available in src.services.ingest,
    mirroring the compatibility layer used in routes/remotes.py.
    """
    from ..services import ingest as ingest_mod  # local import to keep scheduler import‑light

    # Preferred names first
    candidates = [
        ("ingest_index", "kw2"),  # func(db=db, index_url=url)
        ("ingest_remote", "pos"), # func(db, url)
        ("ingest", "pos"),
        ("sync_once", "pos"),
        ("sync_remote", "pos"),
    ]

    for fname, style in candidates:
        fn = getattr(ingest_mod, fname, None)
        if callable(fn):
            try:
                if style == "pos":
                    return fn(db, url)
                if style == "kw2":
                    return fn(db=db, index_url=url)
                # Fallback permutations
            except TypeError:
                try:
                    return fn(db=db, url=url)  # type: ignore
                except Exception:
                    pass
                try:
                    return fn(db=db, index_url=url)  # type: ignore
                except Exception:
                    pass
            # Other exceptions bubble to caller
            raise

    # Batch fallback (functions that accept a list)
    for fname in ("ingest_many", "sync_remotes", "sync_all"):
        fn = getattr(ingest_mod, fname, None)
        if callable(fn):
            out = fn(db, [url])  # type: ignore
            if isinstance(out, list) and out:
                first = out[0]
                return first if isinstance(first, dict) else {"result": first}
            return out if isinstance(out, dict) else {"result": out}

    raise RuntimeError("No compatible ingest function found in src.services.ingest")


def _compact(obj: Dict[str, Any], max_len: int = 256) -> str:
    """
    Compact dict → single‑line JSON truncated for logs.
    """
    try:
        s = json.dumps(obj, separators=(",", ":"), ensure_ascii=False)
        return s if len(s) <= max_len else s[:max_len] + "…"
    except Exception:
        return str(obj)[:max_len]


# --------------------------------------------------------------------------------------
# End
# --------------------------------------------------------------------------------------
