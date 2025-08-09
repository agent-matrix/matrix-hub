from __future__ import annotations

import json
import logging
import time

from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request


log = logging.getLogger("http.req")


def _safe_json_snippet(data: bytes, limit: int = 4096) -> str:
    try:
        s = data[:limit].decode("utf-8", errors="replace")
        obj = json.loads(s)
        # redact common secrets
        if isinstance(obj, dict):
            for k in list(obj.keys()):
                if any(t in k.lower() for t in ("token", "password", "secret")):
                    obj[k] = "***REDACTED***"
        return json.dumps(obj)
    except Exception:
        return "<non-json>"


class RequestLogMiddleware(BaseHTTPMiddleware):
    """Lightweight structured logs around every request.

    Logs: method, path, status, duration_ms, request_id, and a tiny JSON snippet for POST/PUT/PATCH.
    """

    async def dispatch(self, request: Request, call_next):
        start = time.perf_counter()
        rid = getattr(request.state, "request_id", None)
        method = request.method
        path = request.url.path

        body_snippet: str | None = None
        if method in ("POST", "PUT", "PATCH") and ("/install" in path or "/ingest" in path):
            try:
                body = await request.body()
                body_snippet = _safe_json_snippet(body)
            except Exception:
                body_snippet = None

        log.info(
            "request.start",
            extra={"rid": rid, "method": method, "path": path, "body": body_snippet},
        )

        try:
            response = await call_next(request)
            duration = (time.perf_counter() - start) * 1000
            log.info(
                "request.end",
                extra={
                    "rid": rid,
                    "method": method,
                    "path": path,
                    "status": getattr(response, "status_code", None),
                    "duration_ms": round(duration, 2),
                },
            )
            return response
        except Exception:
            duration = (time.perf_counter() - start) * 1000
            log.exception(
                "request.error",
                extra={"rid": rid, "method": method, "path": path, "duration_ms": round(duration, 2)},
            )
            raise
