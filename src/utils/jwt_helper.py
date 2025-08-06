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
    or fall back to ADMIN_TOKEN if minting fails.
    """
    # 1) load inputs
    secret = secret or os.getenv("JWT_SECRET_KEY")
    user   = username or os.getenv("BASIC_AUTH_USERNAME") or "admin"
    now    = int(time.time())

    # 2) attempt mint
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

    # 3) fallback
    fb = fallback_token or os.getenv("ADMIN_TOKEN")
    if fb:
        log.debug("Using fallback ADMIN_TOKEN")
        return fb

    # 4) nothing left
    raise RuntimeError(
        "Unable to obtain admin token: no JWT_SECRET_KEY or fallback ADMIN_TOKEN"
    )
