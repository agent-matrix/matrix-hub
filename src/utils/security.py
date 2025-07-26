"""
Security helpers.

- Simple Bearer token enforcement for admin routes
- If no API token configured, dependency is a no-op (permits all)

Usage in routes:

    from fastapi import Depends, APIRouter
    from ..utils.security import require_api_token

    router = APIRouter()

    @router.post("/catalog/ingest", dependencies=[Depends(require_api_token)])
    def ingest(...): ...
"""

from __future__ import annotations

from typing import Optional

from fastapi import Depends, HTTPException, Request, status

from ..config import settings


def is_auth_enabled() -> bool:
    return bool(settings.API_TOKEN)


def require_api_token(request: Request) -> None:
    """
    FastAPI dependency: enforce simple Bearer token auth if configured.

    Accepts:
      - Authorization: Bearer <token>
      - or query parameter ?token=<token> (useful for local testing)
    """
    if not is_auth_enabled():
        return  # no-op

    auth = request.headers.get("Authorization") or request.headers.get("authorization") or ""
    token = None

    if auth.lower().startswith("bearer "):
        token = auth.split(None, 1)[1].strip()
    elif "token" in request.query_params:
        token = request.query_params.get("token")

    if not token or token != settings.API_TOKEN:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or missing bearer token.",
            headers={"WWW-Authenticate": "Bearer"},
        )
