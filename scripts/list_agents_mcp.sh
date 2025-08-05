#!/usr/bin/env bash
# =============================================================================
# scripts/list_agents_mcp.sh
#
# List all 'agent' and 'mcp_server' entries in the Matrix Hub database.
# =============================================================================
set -Eeuo pipefail

# 1) Change into repo root (assumes scripts/ is one level down)
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# 2) Activate your venv if needed:
#    source .venv/bin/activate

# 3) Run the Python listing script
if [[ ! -f "scripts/list_agents_mcp.py" ]]; then
  echo "ERROR: scripts/list_agents_mcp.py not found." >&2
  exit 1
fi

python3 scripts/list_agents_mcp.py
