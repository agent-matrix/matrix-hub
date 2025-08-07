#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# scripts/list_agents_gateway.sh
# -----------------------------------------------------------------------------
# Usage:
#   ./list_agents_gateway.sh [<ADMIN_TOKEN>]
#
# If you don’t pass a token, this script will:
#   1) Activate the mcpgateway venv
#   2) Read BASIC_AUTH_USERNAME / JWT_SECRET_KEY from env (or use defaults)
#   3) Mint a fresh ADMIN_TOKEN via the mcpgateway utils.create_jwt_token CLI
# -----------------------------------------------------------------------------

# 1) Locate/activate the gateway virtualenv
VENV="./mcpgateway/.venv/bin/activate"
[[ -f "$VENV" ]] || { echo "❌ Virtualenv not found at $VENV"; exit 1; }
# shellcheck disable=SC1090
source "$VENV"
echo "✅ Activated mcpgateway virtualenv"

# 2) Figure out the ADMIN_TOKEN
if [[ -n "${MCP_ADMIN_TOKEN:-}" ]]; then
  TOKEN="$MCP_ADMIN_TOKEN"
  echo "ℹ️  Using ADMIN_TOKEN from MCP_ADMIN_TOKEN env var"
elif [[ $# -ge 1 ]]; then
  TOKEN="$1"
  echo "ℹ️  Using ADMIN_TOKEN from script argument"
else
  # Mint a fresh JWT via the gateway’s CLI helper
  export BASIC_AUTH_USERNAME="${BASIC_AUTH_USERNAME:-admin}"
  export JWT_SECRET_KEY="${JWT_SECRET_KEY:-my-test-key}"
  echo "🔑 Minting temporary ADMIN_TOKEN via mcpgateway.utils.create_jwt_token…"
  TOKEN=$(python -m mcpgateway.utils.create_jwt_token \
            --username "$BASIC_AUTH_USERNAME" \
            --secret   "$JWT_SECRET_KEY" \
            --exp      300)
  echo "✅ Minted new ADMIN_TOKEN"
fi

# 3) Fetch & tabulate gateways
curl -sS \
     -H "Authorization: Bearer $TOKEN" \
     -H "Accept: application/json" \
     "http://localhost:4444/gateways?include_inactive=false" \
| jq -r '
    # header row
    (["ID","Name","Description","URL","Transport"] | @tsv),
    # then each gateway as TSV (fallback to "-")
    ( .[] |
      [
        (.id            // "-"),
        (.name          // "-"),
        (.description   // "-"),
        (.url           // "-"),
        (.transport     // "-")
      ] | @tsv
    )
' | column -t -s $'\t'
