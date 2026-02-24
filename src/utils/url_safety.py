"""
URL safety helpers for SSRF protection.

Provides minimal, non-destructive SSRF hygiene:
- Allowlist hosts if REMOTE_ALLOW_HOSTS is set
- Always block obvious local hosts from REMOTE_BLOCK_HOSTS
"""

from __future__ import annotations

from urllib.parse import urlparse

from fastapi import HTTPException, status

from ..config import settings


def _as_list(v):
    """Convert a value to a list of lowercase, stripped strings."""
    if v is None:
        return []
    if isinstance(v, (list, tuple)):
        return [str(x).strip().lower() for x in v if str(x).strip()]
    s = str(v).strip()
    if not s:
        return []
    # allow comma-separated
    return [x.strip().lower() for x in s.split(",") if x.strip()]


def assert_remote_url_allowed(url: str) -> None:
    """
    Minimal, non-destructive SSRF hygiene:
    - allowlist hosts if REMOTE_ALLOW_HOSTS is set
    - always block obvious local hosts from REMOTE_BLOCK_HOSTS
    """
    p = urlparse(url)
    host = (p.hostname or "").lower()
    if not host:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Invalid remote URL host",
        )

    block = set(_as_list(settings.REMOTE_BLOCK_HOSTS))
    if host in block:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Remote host blocked: {host}",
        )

    allow = set(_as_list(settings.REMOTE_ALLOW_HOSTS))
    if allow and host not in allow:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Remote host not in allowlist: {host}",
        )
