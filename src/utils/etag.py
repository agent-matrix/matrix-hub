"""
ETag / Last-Modified helpers.

- Compute weak ETag for JSON-serializable payloads or bytes
- Evaluate conditional requests (If-None-Match / If-Modified-Since)
- Apply cache headers to a Starlette/FastAPI Response
"""

from __future__ import annotations

import hashlib
import json
from datetime import datetime, timezone
from email.utils import format_datetime, parsedate_to_datetime
from typing import Any, Optional

from starlette.requests import Request
from starlette.responses import Response


def _to_bytes(payload: Any) -> bytes:
    if payload is None:
        return b"null"
    if isinstance(payload, (bytes, bytearray, memoryview)):
        return bytes(payload)
    # Canonical JSON dump for stable hashing
    return json.dumps(payload, separators=(",", ":"), sort_keys=True, ensure_ascii=False).encode("utf-8")


def weak_etag(payload: Any) -> str:
    """
    Compute a weak ETag of the given payload.
    """
    digest = hashlib.md5(_to_bytes(payload)).hexdigest()  # nosec - ETag, not security
    return f'W/"{digest}"'


def strong_etag(payload: Any) -> str:
    """
    Compute a strong ETag (same hash, but without W/ prefix).
    """
    digest = hashlib.md5(_to_bytes(payload)).hexdigest()  # nosec - ETag, not security
    return f'"{digest}"'


def check_not_modified(
    request: Request,
    etag: Optional[str] = None,
    last_modified: Optional[datetime] = None,
) -> bool:
    """
    Return True if the request matches conditional headers (client has fresh copy).

    Checks:
      - If-None-Match against provided ETag
      - If-Modified-Since against provided last_modified
    """
    # ETag
    if etag:
        inm = request.headers.get("if-none-match")
        if inm and _etag_matches(etag, inm):
            return True

    # Last-Modified
    if last_modified:
        ims = request.headers.get("if-modified-since")
        if ims:
            try:
                ims_dt = parsedate_to_datetime(ims)
                if ims_dt.tzinfo is None:
                    ims_dt = ims_dt.replace(tzinfo=timezone.utc)
                lm = last_modified if last_modified.tzinfo else last_modified.replace(tzinfo=timezone.utc)
                if lm <= ims_dt:
                    return True
            except Exception:
                # Ignore parse errors
                pass

    return False


def set_cache_headers(
    response: Response,
    *,
    etag: Optional[str] = None,
    last_modified: Optional[datetime] = None,
    cache_control: str = 'public, max-age=60',
) -> None:
    """
    Apply caching headers to the response.
    """
    if etag:
        response.headers["ETag"] = etag
    if last_modified:
        # RFC 7231 IMF-fixdate
        if last_modified.tzinfo is None:
            last_modified = last_modified.replace(tzinfo=timezone.utc)
        response.headers["Last-Modified"] = format_datetime(last_modified)
    if cache_control:
        response.headers["Cache-Control"] = cache_control


# ---- helpers ----

def _etag_matches(etag: str, if_none_match_value: str) -> bool:
    """
    Compare an ETag against an If-None-Match header value.
    Supports lists and wildcards.
    """
    inm = [x.strip() for x in if_none_match_value.split(",") if x.strip()]
    if "*" in inm:
        return True
    # compare case-sensitively as per RFC semantics
    return etag in inm
