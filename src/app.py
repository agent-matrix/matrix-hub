"""
Matrix Hub — FastAPI application entrypoint.

- Wires core routers: health, catalog, remotes
- Initializes DB connection on startup; disposes on shutdown
- Starts the periodic ingest scheduler; stops it on shutdown
- Adds CORS and a simple request-id middleware
- Registers exception handlers for clean JSON errors
"""

from __future__ import annotations

import logging
import sys
import time
import uuid
import os
from contextlib import asynccontextmanager
from typing import AsyncIterator

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from starlette.middleware.gzip import GZipMiddleware
from starlette.middleware.base import BaseHTTPMiddleware
from .middleware.reqlog import RequestLogMiddleware  # NEW

# --- Added: Alembic imports for DB migrations ---
from alembic import command
from alembic.config import Config as AlembicConfig
from pathlib import Path
# --- end additions ---

# Local settings & modules
from .config import settings
from .db import init_db, close_db
from .routes import health, catalog, remotes
from .routes.catalog_list import router as catalog_list_router
from .workers import scheduler as ingest_scheduler


# ---------- Logging setup ----------
def _configure_logging() -> None:
    """Basic JSON-ish logging to stdout; suitable for containers."""
    level = getattr(logging, settings.LOG_LEVEL.upper(), logging.INFO)
    logging.basicConfig(
        level=level,
        stream=sys.stdout,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    # Reduce noisy third-party loggers if needed
    logging.getLogger("uvicorn.access").setLevel(logging.WARNING)
    logging.getLogger("httpx").setLevel(logging.WARNING)


# ---------- Request ID middleware ----------
class RequestIdMiddleware(BaseHTTPMiddleware):
    """Attach a request-id to every request for tracing."""

    async def dispatch(self, request: Request, call_next):
        rid = request.headers.get("X-Request-ID") or str(uuid.uuid4())
        start = time.perf_counter()
        # expose on request.state and response header
        request.state.request_id = rid
        response = await call_next(request)
        response.headers["X-Request-ID"] = rid
        response.headers["X-Response-Time-ms"] = f"{(time.perf_counter() - start) * 1000:.2f}"
        return response


# ---------- Exception handlers ----------
async def http_exception_handler(request: Request, exc):
    # Let FastAPI/Starlette handle HTTPException defaults
    # but ensure request-id is present
    from fastapi import HTTPException

    if isinstance(exc, HTTPException):
        return JSONResponse(
            status_code=exc.status_code,
            content={
                "error": exc.detail if exc.detail else exc.__class__.__name__,
                "request_id": getattr(request.state, "request_id", None),
            },
        )
    # Fallback
    return JSONResponse(
        status_code=500,
        content={
            "error": "Internal Server Error",
            "request_id": getattr(request.state, "request_id", None),
        },
    )


async def validation_exception_handler(request: Request, exc: RequestValidationError):
    return JSONResponse(
        status_code=422,
        content={
            "error": "ValidationError",
            "detail": exc.errors(),
            "request_id": getattr(request.state, "request_id", None),
        },
    )


async def unhandled_exception_handler(request: Request, exc: Exception):
    logging.getLogger("app").exception("Unhandled exception", exc_info=exc)
    return JSONResponse(
        status_code=500,
        content={
            "error": "Internal Server Error",
            "request_id": getattr(request.state, "request_id", None),
        },
    )


# --- Added: helper to run Alembic migrations at startup ---
def run_migrations() -> None:
    """
    Upgrade the database schema to the latest Alembic revision.
    Uses alembic.ini located at the project root.
    """
    cfg = AlembicConfig(str(Path(__file__).resolve().parents[1] / "alembic.ini"))
    command.upgrade(cfg, "head")
# --- end additions ---


# ---------- Lifespan (startup/shutdown) ----------
@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    # Startup
    _configure_logging()
    log = logging.getLogger("app")
    log.info("Starting Matrix Hub...")

    # Initialize DB and verify connectivity
    try:
        init_db()
        log.info("Database initialized.")
        # --- Added: ensure DB schema is up-to-date ---
        try:
            run_migrations()
            log.info("Database migrations applied (alembic upgrade head).")
        except Exception:
            log.exception("Failed to apply database migrations.")
            raise
        # --- end additions ---
    except Exception:
        log.exception("Failed to initialize database.")
        raise

    # Start the ingest scheduler (APScheduler-based)
    try:
        app.state.scheduler = ingest_scheduler.start_scheduler(app)
        log.info("Ingest scheduler started.")
    except Exception:
        log.exception("Failed to start ingest scheduler.")
        # do not raise—service can still serve search; but log loudly

    # Yield control to the application
    try:
        yield
    finally:
        # Shutdown
        try:
            if getattr(app.state, "scheduler", None):
                ingest_scheduler.stop_scheduler(app.state.scheduler)
                log.info("Ingest scheduler stopped.")
        except Exception:
            log.exception("Error stopping scheduler.")

        try:
            close_db()
            log.info("Database connections disposed.")
        except Exception:
            log.exception("Error closing database connections.")

        log.info("Matrix Hub stopped.")


# ---------- App factory ----------
def create_app() -> FastAPI:
    app = FastAPI(
        title="Matrix Hub",
        version=getattr(settings, "APP_VERSION", "0.1.0"),
        docs_url="/docs",
        redoc_url="/redoc",
        openapi_url="/openapi.json",
        lifespan=lifespan,
    )

    # Middlewares
    app.add_middleware(RequestIdMiddleware)
    # High-signal request/response logging (method, path, status, duration)
    app.add_middleware(RequestLogMiddleware)
    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.CORS_ALLOW_ORIGINS or ["*"],
        allow_credentials=True,
        allow_methods=["GET", "POST", "OPTIONS", "PUT", "PATCH", "DELETE"],
        allow_headers=["*"],
        expose_headers=["X-Request-ID", "X-Response-Time-ms"],
        max_age=3600,
    )
    # Light compression (safe defaults)
    app.add_middleware(GZipMiddleware, minimum_size=1024)

    # Routers
    app.include_router(health.router, tags=["health"])
    # The catalog and remotes routers should define their own subpaths (e.g., /catalog/*).
    app.include_router(catalog.router, tags=["catalog"])
    app.include_router(remotes.router, tags=["remotes"])
    # Our new “List Catalog” endpoint (GET /catalog)
    app.include_router(catalog_list_router, tags=["catalog"])

    # Exception handlers
    app.add_exception_handler(RequestValidationError, validation_exception_handler)
    # HTTP errors (FastAPI's HTTPException)
    from fastapi import HTTPException

    app.add_exception_handler(HTTPException, http_exception_handler)
    app.add_exception_handler(Exception, unhandled_exception_handler)

    # Optional root route
    @app.get("/", tags=["health"])
    async def root():
        return {"service": "matrix-hub", "status": "ok"}

    return app


# ASGI callable for uvicorn/gunicorn
app = create_app()

if __name__ == "__main__":
    import logging
    import uvicorn

    # Ensure our JSON-ish logging also applies here
    logging.basicConfig(
        level=getattr(logging, settings.LOG_LEVEL.upper(), logging.DEBUG),
        stream=sys.stdout,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )

    # Start Uvicorn with our app factory
    uvicorn.run(
        "src.app:app",
        host="0.0.0.0",
        port=int(os.getenv("PORT", 7300)),
        log_level=settings.LOG_LEVEL.lower(),
        reload=True,           # optional for dev
        factory=False,         # app is an instance, not a factory function
    )
