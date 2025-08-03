
# MCP Gateway Verification

After setup and starting the gateway, run a few checks to ensure it’s operational.

## Using the provided script

```bash
make gateway-verify
# or
scripts/verify_servers.sh
```

This will:

1. **Check health endpoint**

   ```bash
   curl -fsS http://$HOST:$PORT/health | jq .
   # Expect: { "status": "ok" }
   ```

2. **List registered servers**

   ```bash
   # Generate a short‑lived admin JWT
   ADMIN_TOKEN=$(
     source mcpgateway/.venv/bin/activate
     python3 -m mcpgateway.utils.create_jwt_token \
       --username "$BASIC_AUTH_USER" \
       --secret   "$JWT_SECRET_KEY" \
       --exp 60
   )

   curl -u "$BASIC_AUTH_USER:$BASIC_AUTH_PASSWORD" \
     -H "Authorization: Bearer $ADMIN_TOKEN" \
     http://$HOST:$PORT/servers | jq .
   # Expect an empty list: []
   ```

3. **(Optional) Additional smoke tests**

   * Probe any custom agent endpoints you may have registered
   * Tail logs: `tail -f mcpgateway/logs/mcpgateway.log` for errors/warnings

## Manual Verification

1. **Open browser**
   Navigate to `http://localhost:4444/admin/`, log in with your Basic Auth user (default `admin`/`changeme`).

2. **Inspect Dashboard**

   * No agents listed initially
   * Check “Servers” tab to confirm the gateway itself is registered

3. **API calls**
   Try a few calls with `curl` or Postman to `/health`, `/servers`, etc.
