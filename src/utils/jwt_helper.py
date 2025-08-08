# src/utils/jwt_helper.py

import os
import time
import logging

# defer PyJWT import so matrix-hub can run without it if not needed
try:
    import jwt
except ImportError:
    jwt = None

log = logging.getLogger(__name__)


def get_mcp_admin_token(
    secret: str | None = None,
    username: str | None = None,
    ttl_seconds: int = 300,
    fallback_token: str | None = None,
) -> str:
    """
    Mint a short-lived HS256 JWT for MCP-Gateway admin calls,
    or fall back to MCP_GATEWAY_TOKEN / ADMIN_TOKEN or HTTP Basic if minting fails.
    """
    # 1) load inputs
    secret = secret or os.getenv("JWT_SECRET_KEY")
    user = (
        username
        or os.getenv("BASIC_AUTH_USERNAME")
        or os.getenv("BASIC_AUTH_USER")
        or "admin"
    )
    now = int(time.time())

    # 2) attempt mint via PyJWT
    if jwt and secret:
        try:
            payload = {"sub": user, "iat": now, "exp": now + ttl_seconds}
            token = jwt.encode(payload, secret, algorithm="HS256")
            log.debug("Minted temporary JWT (expiring in %ds)", ttl_seconds)
            return token
        except Exception as e:
            log.warning("JWT minting failed (%s); falling back: %s", type(e).__name__, e)
    else:
        if not jwt:
            log.warning("PyJWT not installed; cannot mint JWT")
        if not secret:
            log.warning("JWT_SECRET_KEY missing; cannot mint JWT")

    # 3) fallback to explicit tokens in env (prefer MCP_GATEWAY_TOKEN, then ADMIN_TOKEN)
    fb = fallback_token or os.getenv("MCP_GATEWAY_TOKEN") or os.getenv("ADMIN_TOKEN")
    if fb:
        log.debug("Using fallback gateway token from env")
        # Could already be prefixed; client will handle both raw and prefixed values
        return fb

    # 4) fallback to HTTP Basic if credentials present
    pwd = os.getenv("BASIC_AUTH_PASSWORD")
    if user and pwd:
        import base64

        creds = f"{user}:{pwd}".encode("utf-8")
        token = base64.b64encode(creds).decode("utf-8")
        log.debug("Using HTTP Basic auth as fallback")
        return f"Basic {token}"

    # 5) nothing left
    raise RuntimeError(
        "Unable to obtain admin token: no PyJWT, JWT_SECRET_KEY, MCP_GATEWAY_TOKEN/ADMIN_TOKEN or BASIC_AUTH_PASSWORD"
    )
