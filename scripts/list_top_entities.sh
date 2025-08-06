#!/usr/bin/env bash
#
# scripts/list_top_entities.sh
#
# Lists the most recently added entities in each category:
#   - agent
#   - tool
#   - mcp_server
#
# Usage:
#   scripts/list_top_entities.sh [N]
# Where N is the number of most recent records per type (default: 5).
#

set -euo pipefail

COUNT="${1:-5}"

if [[ ! -f scripts/list_top_entities.py ]]; then
  echo "ERROR: scripts/list_top_entities.py not found. Run from repo root." >&2
  exit 1
fi

echo "🔎 Listing top $COUNT entities by type (agent, tool, mcp_server)..."
python3 scripts/list_top_entities.py "$COUNT"
