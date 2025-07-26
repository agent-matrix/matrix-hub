# -*- coding: utf-8 -*-
"""
Minimal client for MCP‑Gateway (admin/public API).

This client talks to the API routers defined in mcpgateway/main.py:
  - /tools       (ToolCreate → ToolRead)
  - /gateways    (GatewayCreate → GatewayRead)
  - /resources   (ResourceCreate → ResourceRead)
  - /prompts     (PromptCreate → PromptRead)

Notes:
- In this gateway, *registering an MCP "server"* is done via **POST /gateways**,
  not /servers. After registration the gateway service connects and lists tools.
- There is no /servers/{id}/discovery endpoint; discovery happens implicitly.
  We expose a no-op trigger_discovery(...) for compatibility with install.py.

Auth:
- Uses Bearer token if provided via settings.MCP_GATEWAY_TOKEN.

Retries:
- Retries transient errors (httpx.RequestError, 5xx) with small backoff.
- Does NOT retry on 4xx (validation/conflict) unless explicitly allowed for 409.

Compatibility shims:
- Free functions: register_tool, register_server, register_resources, register_prompts, trigger_discovery, gateway_health
"""

from __future__ import annotations

import json
import logging
import time
from typing import Any, Dict, Iterable, List, Optional, Union

import httpx

from ..config import settings

logger = logging.getLogger(__name__)


# --------------------------------------------------------------------------------------
# Exceptions
# --------------------------------------------------------------------------------------

class GatewayClientError(RuntimeError):
    """Raised for non-transient HTTP errors when communicating with MCP‑Gateway."""

    def __init__(self, message: str, *, status_code: Optional[int] = None, body: Optional[Any] = None):
        super().__init__(message)
        self.status_code = status_code
        self.body = body

    def __repr__(self) -> str:
        return f"GatewayClientError(status_code={self.status_code}, message={self.args[0]!r})"


# --------------------------------------------------------------------------------------
# Core client
# --------------------------------------------------------------------------------------

class MCPGatewayClient:
    """
    Thin sync client around httpx for MCP‑Gateway admin/public endpoints.
    """

    def __init__(
        self,
        base_url: Optional[str] = None,
        token: Optional[str] = None,
        *,
        timeout: float = 15.0,
        max_retries: int = 3,
        backoff_base: float = 0.5,
    ) -> None:
        self.base_url = (base_url or getattr(settings, "MCP_GATEWAY_URL", None)
                         or getattr(settings, "mcp_gateway_url", "")).rstrip("/")
        self.token = token or getattr(settings, "MCP_GATEWAY_TOKEN", None) or getattr(settings, "mcp_gateway_token", None)
        self.timeout = timeout
        self.max_retries = max_retries
        self.backoff_base = backoff_base

        if not self.base_url:
            raise ValueError("MCP_GATEWAY_URL is not configured.")

        self._headers = {"Accept": "application/json"}
        if self.token:
            self._headers["Authorization"] = f"Bearer {self.token}"

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
        Internal request with simple retry for transient errors.

        If ok_on_conflict=True and the response is 409, we return the response
        instead of raising, so callers can treat it as "already exists".
        """
        url = f"{self.base_url}{path}"
        attempts = self.max_retries if self.max_retries and self.max_retries > 0 else 1

        last_exc: Optional[Exception] = None
        for attempt in range(1, attempts + 1):
            try:
                with httpx.Client(timeout=self.timeout, headers=self._headers) as client:
                    resp = client.request(method, url, json=json_body, params=params)

                # Transients (retry)
                if resp.status_code >= 500:
                    raise httpx.HTTPStatusError(
                        f"Server error {resp.status_code}",
                        request=resp.request,
                        response=resp,
                    )

                # Optional idempotent 409 handling
                if resp.status_code == 409 and ok_on_conflict:
                    return resp

                # Non-transient errors bubble
                if resp.status_code >= 400:
                    try:
                        data = resp.json()
                    except Exception:
                        data = resp.text
                    raise GatewayClientError(
                        f"{method} {path} failed ({resp.status_code})",
                        status_code=resp.status_code,
                        body=data,
                    )

                return resp

            except httpx.HTTPStatusError as e:
                last_exc = e
                self._sleep_backoff(attempt)
                continue
            except httpx.RequestError as e:
                # includes timeouts, network/transport errors
                last_exc = e
                self._sleep_backoff(attempt)
                continue

        # Exhausted retries
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


def register_server(server_spec: Dict[str, Any], *, idempotent: bool = False) -> Dict[str, Any]:
    """
    Compatibility wrapper for install.py.

    IMPORTANT: In this gateway, an MCP 'server' is registered via **/gateways**.
    We normalize the manifest spec and call POST /gateways.
    """
    logger.info("Registering MCP server (as gateway) with MCP‑Gateway (idempotent=%s)", idempotent)
    return _client().create_gateway(server_spec, idempotent=idempotent)


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
