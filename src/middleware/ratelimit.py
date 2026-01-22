"""
Simple rate limiting middleware for public search endpoints.

Extremely small, non-destructive, best-effort limiter.
Limits by client IP for GET /catalog/search only.

Note: in-memory rate limits are not perfect across multiple replicas.
Still useful as a "seatbelt". For production, prefer LB/gateway rate limiting.
"""

from __future__ import annotations

import time
from collections import defaultdict, deque

from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import JSONResponse


class SimpleRateLimitMiddleware(BaseHTTPMiddleware):
    """
    Extremely small, non-destructive, best-effort limiter.
    Limits by client IP for GET /catalog/search only.
    """

    def __init__(self, app, *, max_requests: int = 60, window_seconds: int = 60):
        super().__init__(app)
        self.max_requests = max_requests
        self.window = window_seconds
        self.hits = defaultdict(deque)  # ip -> deque[timestamps]

    async def dispatch(self, request: Request, call_next):
        if request.method == "GET" and request.url.path.startswith("/catalog/search"):
            ip = request.client.host if request.client else "unknown"
            now = time.time()
            q = self.hits[ip]
            # drop old
            while q and q[0] < now - self.window:
                q.popleft()
            if len(q) >= self.max_requests:
                return JSONResponse(
                    {"error": "rate_limited", "detail": "Too many requests"},
                    status_code=429,
                    headers={"Retry-After": "10"},
                )
            q.append(now)
        return await call_next(request)
