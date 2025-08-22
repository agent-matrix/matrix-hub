# -*- coding: utf-8 -*-
"""
Minimal client for MCP-Gateway (admin/public API).

This client wraps the HTTP endpoints exposed by the mcpgateway service:

  - POST /tools      → register new Tool definitions
  - POST /servers    → register MCP “servers”
  - POST /gateways   → register MCP “gateways”
  - POST /resources  → register Resource definitions
  - POST /prompts    → register Prompt templates
  - GET  /tools, /servers, /resources, /prompts → list existing entities

Key behaviors:
  * Auth: Bearer JWT minted just-in-time via get_mcp_admin_token().
  * Retries: automatically retries transient failures (5xx or network errors).
  * Idempotency: callers can set idempotent=True to treat 409 (Conflict) as success.

Performance notes (minor, safe optimizations):
  * Single persistent httpx.Client with HTTP/2 + connection pooling (keep-alive).
  * Bounded concurrency for bulk resource/prompt registration.
"""

from __future__ import annotations

import json
import logging
import time
from typing import Any, Dict, Iterable, List, Optional, Union, TYPE_CHECKING
from concurrent.futures import ThreadPoolExecutor, as_completed  # NEW

import httpx
from pathlib import Path

# Typing-only import to avoid runtime cycles
if TYPE_CHECKING:  # pragma: no cover
    pass

from ..config import settings
from ..utils.jwt_helper import get_mcp_admin_token

logger = logging.getLogger("gateway.client")

# --------------------------------------------------------------------------------------
# Exceptions
# --------------------------------------------------------------------------------------

class GatewayClientError(RuntimeError):
    """Raised for non-transient HTTP errors when communicating with MCP-Gateway."""

    def __init__(
        self,
        message: str,
        *,
        status_code: Optional[int] = None,
        body: Optional[Any] = None,
    ) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.body = body

    def __repr__(self) -> str:
        return (
            f"<GatewayClientError "
            f"status_code={self.status_code!r} "
            f"message={self.args[0]!r} "
            f"body={self.body!r}>"
        )

class InstallError(Exception):
    """Raised when an installation or registration step is invalid or cannot proceed."""
    pass

# --------------------------------------------------------------------------------------
# Core client
# --------------------------------------------------------------------------------------

class MCPGatewayClient:
    """Thin sync client around httpx for MCP-Gateway admin/public endpoints."""

    def __init__(
        self,
        base_url: Optional[str] = None,
        *,
        jwt_secret: Optional[str] = None,
        jwt_username: Optional[str] = None,
        fallback_token: Optional[str] = None,
        timeout: float = 15.0,
        max_retries: int = 3,
        backoff_base: float = 0.5,
    ) -> None:
        self.base_url = (
            base_url
            or getattr(settings, "MCP_GATEWAY_URL", None)
            or ""
        ).rstrip("/")
        if not self.base_url:
            raise ValueError("MCP_GATEWAY_URL is not configured.")

        self.jwt_secret = jwt_secret or getattr(settings, "JWT_SECRET_KEY", None)
        self.jwt_username = jwt_username or getattr(settings, "BASIC_AUTH_USERNAME", None)
        self.fallback_token = fallback_token or getattr(settings, "MCP_GATEWAY_TOKEN", None)

        self.timeout = timeout
        self.max_retries = max_retries
        self.backoff_base = backoff_base

        self._base_headers = {
            "Accept": "application/json",
            "Content-Type": "application/json",
        }

        # NEW: persistent HTTP client with HTTP/2 and connection pooling
        limits = httpx.Limits(
            max_connections=int(getattr(settings, "GATEWAY_HTTP_MAX_CONNECTIONS", 20)),
            max_keepalive_connections=int(getattr(settings, "GATEWAY_HTTP_MAX_KEEPALIVE", 10)),
            keepalive_expiry=float(getattr(settings, "GATEWAY_HTTP_KEEPALIVE_SECS", 30.0)),
        )
        self._client = httpx.Client(  # thread-safe client, reused across requests
            http2=True,
            timeout=self.timeout,
            headers=self._base_headers,
            limits=limits,
        )

    def __del__(self) -> None:  # best-effort close on GC (process exit will also clean up)
        try:
            self._client.close()
        except Exception:
            pass

    # -----------------------
    # Public convenience APIs
    # -----------------------

    def create_tool(self, payload: Dict[str, Any], *, idempotent: bool = False) -> Dict[str, Any]:
        """POST /tools with ToolCreate payload."""
        return self._post_json("/tools", payload, ok_on_conflict=idempotent)

    def create_server(self, payload: Dict[str, Any], *, idempotent: bool = False) -> Dict[str, Any]:
        """
        POST /servers with ServerCreate payload.
        This method normalizes the incoming payload to match the gateway's expected schema.
        """
        # This normalization step is now handled by the register_server orchestrator
        return self._post_json("/servers", payload, ok_on_conflict=idempotent)

    def create_resource(self, payload: Dict[str, Any], *, idempotent: bool = False) -> Dict[str, Any]:
        """POST /resources with ResourceCreate payload."""
        return self._post_json("/resources", payload, ok_on_conflict=idempotent)

    def create_prompt(self, payload: Dict[str, Any], *, idempotent: bool = False) -> Dict[str, Any]:
        """POST /prompts with PromptCreate payload."""
        return self._post_json("/prompts", payload, ok_on_conflict=idempotent)

    def create_gateway(self, payload: Dict[str, Any], *, idempotent: bool = False) -> Dict[str, Any]:
        """POST /gateways with GatewayCreate payload."""
        return self._post_json("/gateways", payload, ok_on_conflict=idempotent)

    def list_servers(self) -> List[Dict[str, Any]]:
        """GET /servers to list all registered servers."""
        return self._get_json("/servers")

    def health(self) -> Dict[str, Any]:
        """Tiny health/ready probe for the gateway."""
        for path in ("/health", "/ready"):
            try:
                resp = self._get_json(path)
                return {"status": "ok", "endpoint": path, "detail": resp}
            except GatewayClientError as e:
                if e.status_code == 404:
                    continue
                return {"status": "error", "endpoint": path, "status_code": e.status_code, "detail": e.body or str(e)}
            except Exception as e:
                return {"status": "error", "endpoint": path, "detail": str(e)}
        return {"status": "unknown", "detail": "No /health or /ready endpoint found."}

    # -----------------------
    # Internal HTTP helpers
    # -----------------------
    def _request(
        self,
        method: str,
        path: str,
        *,
        json_body: Optional[Dict[str, Any]] = None,
        params: Optional[Dict[str, Any]] = None,
        ok_on_conflict: bool = False,
    ) -> httpx.Response:
        """Core HTTP logic with auth, retries, and error handling."""
        url = f"{self.base_url}{path}"
        attempts = max(1, self.max_retries)
        last_exc: Optional[Exception] = None

        for attempt in range(1, attempts + 1):
            try:
                token = get_mcp_admin_token(
                    secret=self.jwt_secret,
                    username=self.jwt_username,
                    ttl_seconds=300,
                    fallback_token=self.fallback_token,
                )
            except Exception as exc:
                raise GatewayClientError(f"Auth token error: {exc}")

            # Accept tokens returned either as a raw JWT or already prefixed ("Bearer ..." or "Basic ...")
            t = (token or "").strip()
            if t.lower().startswith("bearer ") or t.lower().startswith("basic "):
                auth_value = t
            else:
                auth_value = f"Bearer {t}"
            headers = {**self._base_headers, "Authorization": auth_value}

            try:
                logger.debug("gw.request", extra={"method": method, "url": url, "attempt": attempt})
                # REUSE the persistent client; pass per-request headers
                resp = self._client.request(method, url, json=json_body, params=params, headers=headers)

                logger.info("gw.response", extra={"method": method, "url": url, "status": resp.status_code})

                if resp.status_code >= 500:
                    raise httpx.HTTPStatusError(
                        f"Server error {resp.status_code}", request=resp.request, response=resp
                    )

                if resp.status_code == 409 and ok_on_conflict:
                    return resp

                if 400 <= resp.status_code < 500:
                    try:
                        body = resp.json()
                    except Exception:
                        body = resp.text
                    raise GatewayClientError(
                        f"{method} {path} failed ({resp.status_code})",
                        status_code=resp.status_code,
                        body=body,
                    )
                return resp

            except GatewayClientError as exc:
                # logic paths above raise GatewayClientError explicitly
                raise exc
            except httpx.HTTPStatusError as exc:
                last_exc = exc
                logger.warning(
                    "gw.retry.server",
                    extra={
                        "attempt": attempt,
                        "of": attempts,
                        "status": getattr(exc.response, "status_code", None),
                    },
                )
                self._sleep_backoff(attempt)
            except httpx.RequestError as exc:
                last_exc = exc
                logger.warning(
                    "gw.retry.network", extra={"attempt": attempt, "of": attempts, "error": str(exc)}
                )
                self._sleep_backoff(attempt)

        raise GatewayClientError(str(last_exc) if last_exc else "Unknown gateway request error")

    def _get_json(self, path: str, *, params: Optional[Dict[str, Any]] = None) -> Any:
        resp = self._request("GET", path, params=params)
        return self._safe_json(resp)

    def _post_json(self, path: str, body: Dict[str, Any], *, ok_on_conflict: bool = False) -> Dict[str, Any]:
        resp = self._request("POST", path, json_body=body, ok_on_conflict=ok_on_conflict)
        return self._safe_json(resp)

    def _safe_json(self, resp: httpx.Response) -> Any:
        try:
            return resp.json()
        except json.JSONDecodeError:
            return {"raw": resp.text, "status_code": resp.status_code}

    def _sleep_backoff(self, attempt: int) -> None:
        delay = self.backoff_base * (2 ** (attempt - 1))
        time.sleep(min(delay, 5.0))


# --------------------------------------------------------------------------------------
# Module-level singleton + compatibility wrappers (used by install.py)
# --------------------------------------------------------------------------------------

_client_singleton: Optional[MCPGatewayClient] = None

def _client() -> MCPGatewayClient:
    global _client_singleton
    if _client_singleton is None:
        _client_singleton = MCPGatewayClient()
    return _client_singleton

def register_tool(tool_spec: Dict[str, Any], *, idempotent: bool = False) -> Dict[str, Any]:
    """Compatibility wrapper for install.py → registers a Tool."""
    logger.info("Registering tool with MCP-Gateway (idempotent=%s)", idempotent)
    return _client().create_tool(tool_spec, idempotent=idempotent)


def register_resources(resources: Iterable[Dict[str, Any]], *, idempotent: bool = False) -> List[Dict[str, Any]]:
    """
    Bulk helper to register resources (POST /resources per item).

    Minor performance improvement: submit in parallel with bounded workers.
    Keeps behavior/validation identical (raises on error).
    """
    items = list(resources or [])
    if not items:
        return []

    client = _client()
    max_workers = max(1, int(getattr(settings, "GATEWAY_BULK_WORKERS", 8)))

    results: List[Optional[Dict[str, Any]]] = [None] * len(items)
    errors: List[Exception] = []

    def worker(idx: int, payload: Dict[str, Any]) -> None:
        try:
            resp = client.create_resource(payload, idempotent=idempotent)
            rid = resp.get("id")
            if not isinstance(rid, int):
                raise GatewayClientError("Resource response missing numeric 'id'", status_code=None, body=resp)
            results[idx] = resp
        except Exception as e:
            errors.append(e)

    with ThreadPoolExecutor(max_workers=max_workers) as pool:
        futs = [pool.submit(worker, i, p) for i, p in enumerate(items)]
        for f in as_completed(futs):
            _ = f.result()  # propagate exceptions if any (they're also captured in errors)

    if errors:
        # Preserve previous semantics: raise on failure.
        e = errors[0]
        logger.error("Resource registration failed: %s", e)
        if isinstance(e, GatewayClientError):
            raise e
        raise GatewayClientError(str(e))

    return [r for r in results if r is not None]


def register_prompts(prompts: Iterable[Dict[str, Any]], *, idempotent: bool = False) -> List[Dict[str, Any]]:
    """
    Bulk helper to register prompts (POST /prompts per item).

    Minor performance improvement: submit in parallel with bounded workers.
    Keeps behavior/validation identical (raises on error).
    """
    items = list(prompts or [])
    if not items:
        return []

    client = _client()
    max_workers = max(1, int(getattr(settings, "GATEWAY_BULK_WORKERS", 8)))

    results: List[Optional[Dict[str, Any]]] = [None] * len(items)
    errors: List[Exception] = []

    def worker(idx: int, payload: Dict[str, Any]) -> None:
        try:
            resp = client.create_prompt(payload, idempotent=idempotent)
            pid = resp.get("id")
            if not isinstance(pid, int):
                raise GatewayClientError("Prompt response missing numeric 'id'", status_code=None, body=resp)
            results[idx] = resp
        except Exception as e:
            errors.append(e)

    with ThreadPoolExecutor(max_workers=max_workers) as pool:
        futs = [pool.submit(worker, i, p) for i, p in enumerate(items)]
        for f in as_completed(futs):
            _ = f.result()

    if errors:
        e = errors[0]
        logger.error("Prompt registration failed: %s", e)
        if isinstance(e, GatewayClientError):
            raise e
        raise GatewayClientError(str(e))

    return [r for r in results if r is not None]


def register_gateway(gateway_spec: Dict[str, Any], *, idempotent: bool = False) -> Dict[str, Any]:
    """Compatibility wrapper: registers a Gateway (POST /gateways)."""
    logger.info("Registering gateway with MCP-Gateway (idempotent=%s)", idempotent)
    return _client().create_gateway(gateway_spec, idempotent=idempotent)


def register_server(server_spec: Dict[str, Any], *, idempotent: bool = False) -> Dict[str, Any]:
    """
    Orchestrates two-step registration for servers/gateways:
        1) create resources (inline or repo) and get numeric IDs
        2) POST to /servers or /gateways based on presence of 'url'
    """
    client = _client()

    # Step 1: register artifacts as resources
    resource_ids: List[int] = []
    for art in server_spec.get('artifacts', []):
        kind = art.get('kind')
        spec = art.get('spec', {})
        if kind == 'inline':
            path = spec.get('path')
            if not path:
                raise InstallError("Inline artifact spec missing 'path'.")
            code = Path(path).read_text(encoding='utf-8')
            r_payload = {
                'id': f"{server_spec['name']}-code",
                'name': f"{server_spec['name']} code",
                'type': 'inline',
                'uri': f"file://{path}",
                'content': code,
            }
        else:
            uri = spec.get('repo') or spec.get('url')
            if not uri:
                raise InstallError("Artifact spec missing 'repo' or 'url'.")
            r_payload = {
                'id': spec.get('id', f"{server_spec['name']}-artifact"),
                'name': spec.get('id', f"{server_spec['name']}-artifact"),
                'type': kind,
                'uri': uri,
            }
        try:
            resp = client.create_resource(r_payload, idempotent=idempotent)
            rid = resp.get('id')
            if not isinstance(rid, int):
                raise GatewayClientError("Resource response missing numeric 'id'", status_code=None, body=resp)
            resource_ids.append(rid)
        except GatewayClientError as e:
            logger.error("Failed to register resource '%s': %s", r_payload['id'], e)
            raise

    # ------------------------------------------------------------------
    # Step 2: compose payload (support BOTH flattened and manifest-shaped inputs)
    # ------------------------------------------------------------------
    srv = (server_spec.get('server') or {}) if isinstance(server_spec.get('server'), dict) else {}

    name = srv.get('name', server_spec.get('name'))
    description = srv.get('description', server_spec.get('description', ''))

    # Prefer flattened associated_* if provided; otherwise derive from mcp_registration
    assoc_tools = server_spec.get('associated_tools')
    if assoc_tools is None:
        assoc_tools = ((server_spec.get('mcp_registration') or {}).get('tool') or {}).get('id', [])
    assoc_resources = server_spec.get('associated_resources', resource_ids or [])
    if not assoc_resources:
        assoc_resources = resource_ids or []
    assoc_prompts = server_spec.get('associated_prompts', (server_spec.get('mcp_registration') or {}).get('prompts', []))

    def _as_list(v):
        if v is None:
            return []
        if isinstance(v, (list, tuple)):
            return list(v)
        return [v]

    payload: Dict[str, Any] = {
        'name': name,
        'description': description,
        'associated_tools': _as_list(assoc_tools),
        'associated_resources': _as_list(assoc_resources),
        'associated_prompts': _as_list(assoc_prompts),
    }

    # Determine URL presence from flat or nested shape
    url = server_spec.get('url') or srv.get('url')
    transport = (server_spec.get('transport') or srv.get('transport') or '').upper()
    if url:
        url = url.rstrip('/')
        # Normalize SSE to /messages/
        if transport == 'SSE' and not url.endswith('/messages/'):
            if url.endswith('/messages'):
                url = f"{url}/"
            else:
                url = f"{url}/messages/"
        payload['url'] = url

    try:
        # Route correctly: URL present => Federated Gateway, else Virtual Server
        if payload.get('url'):
            resp = client.create_gateway(payload, idempotent=idempotent)
        else:
            resp = client.create_server(payload, idempotent=idempotent)
        return resp
    except GatewayClientError as e:
        logger.error("Server/Gateway registration failed: %s", e)
        raise


def trigger_discovery(server_id_or_response: Union[str, Dict[str, Any]]) -> Dict[str, Any]:
    """No-op shim for compatibility."""
    sid: Optional[str] = None
    if isinstance(server_id_or_response, dict):
        sid = str(server_id_or_response.get("id") or server_id_or_response.get("uid") or "")
    else:
        sid = str(server_id_or_response or "")
    logger.info("Discovery is automatic in this gateway (no-op). server_id=%s", sid)
    return {"status": "ok", "message": "Discovery happens automatically on gateway registration."}


def gateway_health() -> Dict[str, Any]:
    """Convenience wrapper to probe the gateway health/ready endpoint."""
    return _client().health()
