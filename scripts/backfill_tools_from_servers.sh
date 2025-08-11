#!/usr/bin/env bash
set -euo pipefail
echo "🔧 Backfilling tools from existing mcp_server rows…"
python3 scripts/backfill_tools_from_servers.py
echo "✅ Done. Now listing tools:"
bash scripts/list_tools.sh
