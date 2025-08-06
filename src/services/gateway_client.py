# -*- coding: utf-8 -*-
"""
Minimal client for MCP-Gateway (admin/public API).

This client wraps the HTTP endpoints exposed by the mcpgateway service:

  - POST /tools       → register new Tool definitions
  - POST /gateways    → register MCP “servers” (gateways)
  - POST /resources   → register Resource definitions
  - POST /prompts     → register Prompt templates
  - GET  /tools, /gateways, /resources, /prompts → list existing entities

Key behaviors:
  * Auth: Bearer JWT minted just-in-time via get_mcp_admin_token().
          Falls back to settings.MCP_GATEWAY_TOKEN if minting fails.
  * Retries: automatically retries transient failures (5xx or network errors)
             with exponential backoff. Does not retry 4xx except optional
             idempotent 409 handling.
  * Idempotency: callers can set `idempotent=True` to treat 409 (Conflict)
                 as a no-op success.
  * Compatibility: free functions at module level for install.py:
      - register_tool, register_server, register_resources, register_prompts,
        trigger_discovery, gateway_health
"""

from __future__ import annotations

import json
import logging
import time
from typing import Any, Dict, Iterable, List, Optional, Union

import httpx

from ..config import settings
from ..utils.jwt_helper import get_mcp_admin_token

logger = logging.getLogger(__name__)


# --------------------------------------------------------------------------------------
# Exceptions
# --------------------------------------------------------------------------------------

class GatewayClientError(RuntimeError):
    """
    Raised for non-transient HTTP errors when communicating with MCP-Gateway.

    Attributes:
      status_code: HTTP status code of the failed response (if available).
      body: parsed JSON or raw text body from the response (if available).
    """

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


# --------------------------------------------------------------------------------------
# Core client
# --------------------------------------------------------------------------------------

class MCPGatewayClient:
    """
    Thin sync client around httpx for MCP-Gateway admin/public endpoints.

    Injects a fresh HS256 Bearer token on every request (by calling
    get_mcp_admin_token()), so tokens never expire mid-batch. Falls back
    to a static ADMIN_TOKEN if necessary.

    Usage:
        client = MCPGatewayClient(
            base_url="https://gateway.example.com",
            jwt_secret="mysecret",
            jwt_username="admin",
            fallback_token="STATIC_ADMIN_TOKEN",
        )
        client.create_tool({...})
        client.create_gateway({...})
    """

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
        # 1) Base URL
        self.base_url = (
            base_url
            or getattr(settings, "MCP_GATEWAY_URL", None)
            or getattr(settings, "mcp_gateway_url", None)
            or ""
        ).rstrip("/")
        if not self.base_url:
            raise ValueError("MCP_GATEWAY_URL is not configured.")

        # 2) JWT parameters (mint just-in-time)
        self.jwt_secret     = jwt_secret     or getattr(settings, "JWT_SECRET_KEY", None)
        self.jwt_username   = jwt_username   or getattr(settings, "BASIC_AUTH_USERNAME", None)
        self.fallback_token = fallback_token or getattr(settings, "MCP_GATEWAY_TOKEN", None)

        # 3) HTTP/retry configuration
        self.timeout     = timeout
        self.max_retries = max_retries
        self.backoff_base = backoff_base

        # 4) Base headers (will inject Authorization dynamically)
        self._base_headers = {
            "Accept": "application/json",
            "Content-Type": "application/json",
        }

    # -----------------------
    # Public convenience APIs
    # -----------------------

    def create_tool(self, payload: Dict[str, Any], *, idempotent: bool = False) -> Dict[str, Any]:
        """
        POST /tools with ToolCreate payload.

        Note: Gateway's ToolCreate accepts either "input_schema" or alias "inputSchema".
        """
        return self._post_json("/tools", payload, ok_on_conflict=idempotent)

    def create_gateway(self, payload: Dict[str, Any], *, idempotent: bool = False) -> Dict[str, Any]:
        """
        POST /gateways with GatewayCreate payload.

        Manifest `mcp_registration.server` may use transport names like WEBSOCKET.
        Map them to gateway's supported transports: SSE | HTTP | STDIO | STREAMABLEHTTP.
        """
        normalized = self._normalize_gateway_payload(payload)
        return self._post_json("/gateways", normalized, ok_on_conflict=idempotent)

    def create_resource(self, payload: Dict[str, Any], *, idempotent: bool = False) -> Dict[str, Any]:
        """
        POST /resources with ResourceCreate payload.
        """
        return self._post_json("/resources", payload, ok_on_conflict=idempotent)

    def create_prompt(self, payload: Dict[str, Any], *, idempotent: bool = False) -> Dict[str, Any]:
        """
        POST /prompts with PromptCreate payload.
        """
        return self._post_json("/prompts", payload, ok_on_conflict=idempotent)

    def list_tools(self, include_inactive: bool = False) -> List[Dict[str, Any]]:
        """
        GET /tools (optionally include inactive).
        """
        params = {"include_inactive": str(include_inactive).lower()}
        return self._get_json("/tools", params=params)

    def health(self) -> Dict[str, Any]:
        """
        Tiny health/ready probe for the gateway.

        Tries /health, then /ready. Returns a structured dict instead of raising.
        """
        for path in ("/health", "/ready"):
            try:
                resp = self._get_json(path)
                # If the endpoint returns a simple truthy object, call it ok.
                return {"status": "ok", "endpoint": path, "detail": resp}
            except GatewayClientError as e:
                if e.status_code == 404:
                    # Try the next path
                    continue
                return {"status": "error", "endpoint": path, "status_code": e.status_code, "detail": e.body or str(e)}
            except Exception as e:  # network/parse issues
                return {"status": "error", "endpoint": path, "detail": str(e)}
        return {"status": "unknown", "detail": "No /health or /ready endpoint found."}

    # -----------------------
    # Internal HTTP helpers
    # -----------------------

    def _normalize_gateway_payload(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        """
        Map manifest's server spec to GatewayCreate.

        Expected input (typical from manifest):
          {
            "name": "pdf-summarizer-gw",
            "transport": "WEBSOCKET" | "HTTP" | "STDIO" | "STREAMABLEHTTP",
            "url": "http://host:port/mcp",
            "description": "...",
            # optional auth:
            #   "auth": {"type": "basic"|"bearer"|"headers", ...}
            # or direct fields: "auth_type", "auth_username", ...
          }

        GatewayCreate expects:
          name, url, description?, transport in {"SSE","HTTP","STDIO","STREAMABLEHTTP"},
          auth_type?, auth_username?, auth_password?, auth_token?, auth_header_key?, auth_header_value?
        """
        transport_map = {
            "WEBSOCKET": "SSE",            # gateway does not expose WS; SSE is the usual HTTP transport here
            "HTTP": "HTTP",
            "STDIO": "STDIO",
            "STREAMABLEHTTP": "STREAMABLEHTTP",
            "SSE": "SSE",
        }

        out = dict(payload)  # shallow copy
        # Normalize transport
        t_in = str(out.get("transport", "SSE")).upper()
        out["transport"] = transport_map.get(t_in, "SSE")

        # Normalize auth
        if "auth" in out and isinstance(out["auth"], dict):
            auth = out["auth"]
            at = (auth.get("type") or "").lower()
            if at in {"basic", "bearer", "headers"}:
                out["auth_type"] = at
            # Basic
            if "username" in auth:
                out["auth_username"] = auth["username"]
            if "password" in auth:
                out["auth_password"] = auth["password"]
            # Bearer
            if "token" in auth:
                out["auth_token"] = auth["token"]
            # Headers
            if "header_key" in auth:
                out["auth_header_key"] = auth["header_key"]
            if "header_value" in auth:
                out["auth_header_value"] = auth["header_value"]

        return out

    def _request(
        self,
        method: str,
        path: str,
        *,
        json_body: Optional[Dict[str, Any]] = None,
        params: Optional[Dict[str, Any]] = None,
        ok_on_conflict: bool = False,
    ) -> httpx.Response:
        """
        Core HTTP logic:

          1. Mint a fresh JWT (or fallback) for Authorization.
          2. Send request with retries on 5xx & network errors.
          3. Optionally treat 409 as success if ok_on_conflict=True.
          4. Raise GatewayClientError on non-transient 4xx or exhausted retries.
        """
        url = f"{self.base_url}{path}"
        attempts = max(1, self.max_retries)
        last_exc: Optional[Exception] = None

        for attempt in range(1, attempts + 1):
            # 1) Mint or retrieve token
            try:
                token = get_mcp_admin_token(
                    secret        = self.jwt_secret,
                    username      = self.jwt_username,
                    ttl_seconds   = 300,
                    fallback_token= self.fallback_token,
                )
            except Exception as exc:
                # If even fallback fails, abort immediately
                raise GatewayClientError(f"Auth token error: {exc}")

            headers = {
                **self._base_headers,
                "Authorization": f"Bearer {token}",
            }

            try:
                # 2) Perform HTTP call
                with httpx.Client(timeout=self.timeout, headers=headers) as client:
                    resp = client.request(method, url, json=json_body, params=params)

                # 3) Check for transient server errors
                if resp.status_code >= 500:
                    raise httpx.HTTPStatusError(
                        f"Server error {resp.status_code}", request=resp.request, response=resp
                    )

                # 4) Handle idempotent conflict
                if resp.status_code == 409 and ok_on_conflict:
                    return resp

                # 5) Non-transient client errors
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

                # 6) Success
                return resp

            except httpx.HTTPStatusError as exc:
                last_exc = exc
                logger.warning("Attempt %d/%d: server error, retrying…", attempt, attempts)
                self._sleep_backoff(attempt)

            except httpx.RequestError as exc:
                last_exc = exc
                logger.warning("Attempt %d/%d: network error (%s), retrying…", attempt, attempts, exc)
                self._sleep_backoff(attempt)

        # 7) Exhausted retries
        if isinstance(last_exc, GatewayClientError):
            raise last_exc
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
        # Simple exponential backoff with jitter
        delay = self.backoff_base * (2 ** (attempt - 1))
        delay = delay * (0.5 + 0.5)  # simple jitter placeholder
        time.sleep(min(delay, 5.0))   # cap to 5s to keep installs snappy

    def create_server(
        self,
        payload: Dict[str, Any],
        *,
        idempotent: bool = False,
    ) -> Dict[str, Any]:
        """
        POST /servers with the ServerCreate payload:
          name, description, associated_tools, associated_resources, associated_prompts
        """
        return self._post_json("/servers", payload, ok_on_conflict=idempotent)


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
    """
    Compatibility wrapper for install.py → registers a Tool.
    Set idempotent=True to treat 409 conflicts as 'already exists'.
    """
    logger.info("Registering tool with MCP‑Gateway (idempotent=%s)", idempotent)
    return _client().create_tool(tool_spec, idempotent=idempotent)

def register_server(
    server_spec: Dict[str, Any],
    *,
    idempotent: bool = False
) -> Dict[str, Any]:
    """
    Compatibility wrapper for install.py.

    Registers an MCP server via POST /servers (not /gateways).
    The payload must include:
      - name: str
      - description: str
      - associated_tools: List[str]
      - associated_resources: List[str]
      - associated_prompts: Optional[List[str]]

    Args:
        server_spec: dict with the fields above, typically taken from
                     manifest["mcp_registration"]["server"] normalized.
        idempotent:   if True, treats HTTP 409 (Conflict) as success.

    Returns:
        The parsed JSON response from the Gateway on success.

    Raises:
        GatewayClientError on any non-transient HTTP error (4xx except
        409 when idempotent=True, or 5xx after retries).
    """
    logger.info(
        "Registering MCP server via /servers (idempotent=%s)", 
        idempotent
    )
    return _client().create_server(server_spec, idempotent=idempotent)


def register_resources(resources: Iterable[Dict[str, Any]], *, idempotent: bool = False) -> List[Dict[str, Any]]:
    """
    Bulk helper to register resources (POST /resources per item).
    """
    results: List[Dict[str, Any]] = []
    for res in resources or []:
        try:
            results.append(_client().create_resource(res, idempotent=idempotent))
        except GatewayClientError as e:
            logger.error("Resource registration failed: %s", e)
            results.append({"error": str(e), "status_code": e.status_code, "body": e.body})
    return results


def register_prompts(prompts: Iterable[Dict[str, Any]], *, idempotent: bool = False) -> List[Dict[str, Any]]:
    """
    Bulk helper to register prompts (POST /prompts per item).
    """
    results: List[Dict[str, Any]] = []
    for p in prompts or []:
        try:
            results.append(_client().create_prompt(p, idempotent=idempotent))
        except GatewayClientError as e:
            logger.error("Prompt registration failed: %s", e)
            results.append({"error": str(e), "status_code": e.status_code, "body": e.body})
    return results


def trigger_discovery(server_id_or_response: Union[str, Dict[str, Any]]) -> Dict[str, Any]:
    """
    No-op shim for compatibility.

    This gateway performs discovery of tools as part of Gateway registration.
    There is no /servers/{id}/discovery endpoint.

    We return a success message so install flow can proceed without special cases.
    """
    # Extract an ID if present, for logging only
    sid: Optional[str] = None
    if isinstance(server_id_or_response, dict):
        sid = str(server_id_or_response.get("id") or server_id_or_response.get("uid") or "")
    else:
        sid = str(server_id_or_response or "")

    logger.info("Discovery is automatic in this gateway (no-op). server_id=%s", sid)
    return {"status": "ok", "message": "Discovery happens automatically on gateway registration."}


def gateway_health() -> Dict[str, Any]:
    """
    Convenience wrapper to probe the gateway health/ready endpoint.
    """
    return _client().health()
