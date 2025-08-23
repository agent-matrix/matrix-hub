#!/usr/bin/env bash
# Check a remote Matrix Hub catalog and report if it's effectively empty.
# - Loads .env automatically (uses MATRIX_HUB_BASE or HUB_BASE)
# - Sends optional Bearer TOKEN if present
# - Runs health/config + several search probes
#
# Usage:
#   chmod +x scripts/check_remote_hub.sh
#   scripts/check_remote_hub.sh
#
# Env vars (read from .env if present):
#   MATRIX_HUB_BASE  preferred base (e.g., https://api.matrixhub.io)
#   HUB_BASE         fallback base
#   TOKEN            optional Bearer token for protected hubs
#   TIMEOUT_S        curl timeout (default 12)

set -Eeuo pipefail

# --- Load .env if present ---
if [[ -f .env ]]; then
  echo "▶ Loading environment from .env"
  set -a; # shellcheck disable=SC1091
  source .env
  set +a
fi

BASE="${MATRIX_HUB_BASE:-${HUB_BASE:-https://api.matrixhub.io}}"
BASE="${BASE%/}"
TOKEN="${TOKEN:-}"
TIMEOUT_S="${TIMEOUT_S:-12}"

C_RESET='\033[0m'; C_BOLD='\033[1m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_CYAN='\033[0;36m'

hr(){ printf '%*s\n' "$(tput cols 2>/dev/null || echo 80)" '' | tr ' ' '-'; }

auth_args=()
[[ -n "$TOKEN" ]] && auth_args=(-H "Authorization: Bearer $TOKEN")

say(){ printf "%b\n" "$*"; }

curl_i() {
  # curl with headers (-i) shown; do not fail the script on non-2xx
  local url="$1"; shift
  curl -sS -L -m "$TIMEOUT_S" -i -H 'Accept: application/json' "${auth_args[@]}" "$@" "$url" || true
}

parse_total() {
  # Fetch JSON body only and try to extract `.total`. Prints number or "unknown".
  local url="$1"; shift
  local body
  body="$(curl -sS -L -m "$TIMEOUT_S" -H 'Accept: application/json' "${auth_args[@]}" "$@" "$url" || true)"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$body" | jq -r 'try .total // "unknown"'
  else
    # crude fallback: look for "total": <num>
    local t
    t="$(printf '%s' "$body" | sed -n 's/.*"total"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n1)"
    [[ -n "$t" ]] && echo "$t" || echo "unknown"
  fi
}

total_acc=0

echo
say "🏷  Base: ${C_CYAN}${BASE}${C_RESET}"
[[ -n "$TOKEN" ]] && say "🔑 Using Bearer token from \$TOKEN"

# --- Health ---
hr; say "▶ ${C_CYAN}Health${C_RESET} ${BASE}/health"
curl_i "${BASE}/health"
echo

# --- Config (ok if 404) ---
hr; say "▶ ${C_CYAN}Config${C_RESET} ${BASE}/config (OK if 404)"
curl_i "${BASE}/config"
echo

# --- Basic reachability: q=test, limit=1 ---
hr; say "▶ ${C_CYAN}Search (smoke)${C_RESET} ${BASE}/catalog/search?q=test&limit=1"
curl_i "${BASE}/catalog/search" --get --data-urlencode "q=test" --data-urlencode "limit=1"
t1="$(parse_total "${BASE}/catalog/search" --get --data-urlencode "q=test" --data-urlencode "limit=1")"
say "→ total=${C_BOLD}${t1}${C_RESET}"
[[ "$t1" =~ ^[0-9]+$ ]] && total_acc=$((total_acc + t1))
echo

# --- Primary check aligned with CLI defaults ---
hr; say "▶ ${C_CYAN}Search (CLI-like)${C_RESET} q='Hello World' type=mcp_server mode=keyword include_pending=true limit=5"
curl_i "${BASE}/catalog/search" --get \
  --data-urlencode "q=Hello World" \
  --data-urlencode "type=mcp_server" \
  --data-urlencode "mode=keyword" \
  --data-urlencode "include_pending=true" \
  --data-urlencode "limit=5"
t2="$(parse_total "${BASE}/catalog/search" --get \
  --data-urlencode "q=Hello World" \
  --data-urlencode "type=mcp_server" \
  --data-urlencode "mode=keyword" \
  --data-urlencode "include_pending=true" \
  --data-urlencode "limit=5")"
say "→ total=${C_BOLD}${t2}${C_RESET}"
[[ "$t2" =~ ^[0-9]+$ ]] && total_acc=$((total_acc + t2))
echo

# --- Mode sweep: keyword / semantic / hybrid ---
for MODE in keyword semantic hybrid; do
  hr; say "▶ ${C_CYAN}Search (mode=${MODE})${C_RESET} q='Hello' include_pending=true limit=5"
  curl_i "${BASE}/catalog/search" --get \
    --data-urlencode "q=Hello" \
    --data-urlencode "mode=${MODE}" \
    --data-urlencode "limit=5" \
    --data-urlencode "include_pending=true"
  tx="$(parse_total "${BASE}/catalog/search" --get \
    --data-urlencode "q=Hello" \
    --data-urlencode "mode=${MODE}" \
    --data-urlencode "limit=5" \
    --data-urlencode "include_pending=true")"
  say "→ total(${MODE})=${C_BOLD}${tx}${C_RESET}"
  [[ "$tx" =~ ^[0-9]+$ ]] && total_acc=$((total_acc + tx))
  echo
done

# --- Summary ---
hr
if [[ "$total_acc" -gt 0 ]]; then
  say "✅ ${C_GREEN}Catalog appears NOT EMPTY${C_RESET} (sum of totals across probes: ${C_BOLD}${total_acc}${C_RESET})"
else
  say "⚠️  ${C_YELLOW}Catalog appears EMPTY${C_RESET} (sum of totals = ${C_BOLD}${total_acc}${C_RESET})"
  say "   → Add remotes and ingest:"
  say "     curl -X POST '${BASE}/remotes' -H 'Content-Type: application/json' -H 'Authorization: Bearer …' \\"
  say "          -d '{\"url\":\"https://raw.githubusercontent.com/agent-matrix/catalog/main/index.json\"}'"
  say "     curl -X POST '${BASE}/ingest' -H 'Authorization: Bearer …'"
fi
hr
