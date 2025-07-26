"""
Structured logging utilities.

- JSON formatter with consistent fields
- Correlation ID via contextvars (works with a simple middleware)
- Helper to configure root logging for containerized environments
"""

from __future__ import annotations

import json
import logging
import os
import sys
import time
from contextvars import ContextVar
from typing import Any, Dict, Optional

# Public context var for correlation ID
request_id_ctx: ContextVar[Optional[str]] = ContextVar("request_id", default=None)


class JsonFormatter(logging.Formatter):
    """
    Minimal JSON log formatter.

    Produces a single line JSON object with common fields and includes
    the correlation ID when available (from context var).
    """

    def format(self, record: logging.LogRecord) -> str:
        payload: Dict[str, Any] = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime()),
            "level": record.levelname,
            "logger": record.name,
            "msg": record.getMessage(),
        }

        rid = request_id_ctx.get()
        if rid:
            payload["request_id"] = rid

        # Extras
        if record.exc_info:
            payload["exc_info"] = self.formatException(record.exc_info)

        # Attach module/file/line for debug levels
        if record.levelno <= logging.DEBUG:
            payload["module"] = record.module
            payload["filename"] = record.filename
            payload["lineno"] = record.lineno

        return json.dumps(payload, ensure_ascii=False)


def configure_json_logging(level: str | int = "INFO") -> None:
    """
    Configure root logger with JsonFormatter to stdout.
    """
    if isinstance(level, str):
        level = getattr(logging, level.upper(), logging.INFO)

    root = logging.getLogger()
    root.handlers.clear()
    root.setLevel(level)  # type: ignore[arg-type]

    handler = logging.StreamHandler(stream=sys.stdout)
    handler.setFormatter(JsonFormatter())
    root.addHandler(handler)

    # Quiet noisy libraries by default
    logging.getLogger("uvicorn.access").setLevel(logging.WARNING)
    logging.getLogger("httpx").setLevel(logging.WARNING)


# Optional middleware to set/reset context var for FastAPI
try:
    from starlette.middleware.base import BaseHTTPMiddleware
    from starlette.types import ASGIApp, Receive, Scope, Send
    from starlette.requests import Request
    from starlette.responses import Response

    class CorrelationIdMiddleware(BaseHTTPMiddleware):
        """
        Extracts/assigns a request ID and sets it in the context var,
        so all logs within the request include the correlation id.
        """

        def __init__(self, app: ASGIApp, header_name: str = "X-Request-ID"):
            super().__init__(app)
            self.header_name = header_name

        async def dispatch(self, request: Request, call_next):
            rid = request.headers.get(self.header_name) or request.headers.get("x-request-id")
            if not rid:
                # fallback to any prior middleware that may have set it
                rid = getattr(request.state, "request_id", None)
            token = request_id_ctx.set(rid)
            try:
                response: Response = await call_next(request)
                if rid:
                    response.headers.setdefault(self.header_name, rid)
                return response
            finally:
                request_id_ctx.reset(token)
except Exception:  # pragma: no cover
    # If starlette isn't available for some reason, the middleware won't be exported.
    CorrelationIdMiddleware = None  # type: ignore
