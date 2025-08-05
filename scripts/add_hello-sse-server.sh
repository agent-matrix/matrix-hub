#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Adds the hello-sse-server MCP server manifest to matrix/index.json.
# Optionally, you can export HUB_URL and ADMIN_TOKEN to also register with Hub.
# -----------------------------------------------------------------------------

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

pushd "$REPO_ROOT" >/dev/null

examples/add_mcp_server.sh \
  --id hello-sse-server \
  --version 0.1.0 \
  --name "Hello World MCP (SSE)" \
  --manifest-url "https://raw.githubusercontent.com/ruslanmv/hello-mcp/refs/heads/main/matrix/hello-server.manifest.json"

popd >/dev/null
