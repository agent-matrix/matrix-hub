"""
Routes package marker and router aggregator.

Usage:
    from fastapi import FastAPI
    from src.routes import get_api_router

    app = FastAPI()
    app.include_router(get_api_router())
"""

from __future__ import annotations

from fastapi import APIRouter


def get_api_router() -> APIRouter:
    router = APIRouter()

    # Import sub-routers lazily to avoid circular imports during app startup.
    try:
        from .health import router as health_router  # type: ignore
        router.include_router(health_router)
    except Exception:
        pass

    try:
        from .catalog import router as catalog_router  # type: ignore
        router.include_router(catalog_router, prefix="/catalog")
    except Exception:
        pass

    try:
        from .remotes import router as remotes_router  # type: ignore
        router.include_router(remotes_router, prefix="/catalog")
    except Exception:
        pass

    try:
        from .gateway import router as gateway_router  # type: ignore
        router.include_router(gateway_router, prefix="/gateway")
    except Exception:
        # gateway routes are optional
        pass

    return router
