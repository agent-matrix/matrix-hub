"""
Workers package marker.

Provides an optional scheduler hook that can be used by app.py to start
periodic ingestion without importing the whole scheduler module up-front.
"""

from __future__ import annotations

from typing import Any


def try_start_scheduler(app: Any) -> None:
    """
    Attempt to start the APScheduler ingest job if the scheduler module exists.
    Safe no-op if imports fail (e.g., during unit tests).
    """
    try:
        from .scheduler import start_scheduler  # type: ignore
    except Exception:
        return
    try:
        start_scheduler(app)
    except Exception:
        # Fail soft; the API should still run even if background jobs cannot start.
        return
