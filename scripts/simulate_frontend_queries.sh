#!/usr/bin/env bash
# Simulate MatrixHub search from outside the frontend.
# Compares direct Hub call vs Vercel /api/search proxy.
# Automatically loads a .env file if present.
#
# Usage:
#   ./simulate_frontend_queries.sh "hello"
#   SKIP_HEALTH_CHECKS=true ./simulate_frontend_queries.sh "search term"
#
# Optional env (can be set in a .env file):
#   HUB_BASE             (default: https://api.matrixhub.io)
#   SITE_URL             (default: https://matrixhub.io)
#   TOKEN                (Bearer token; omitted if empty)
#   TIMEOUT_S            (default: 12)
#   SKIP_HEALTH_CHECKS   (set to "true" to skip /health and /ready checks)
#   (and other search params like LIMIT, OFFSET, TYPE, etc.)

set -Eeuo pipefail

# --- Load .env file if it exists ---
if [ -f .env ]; then
  echo "▶ Loading environment variables from .env file..."
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

# --- Variables and Defaults ---
Q="${1:-hello}"

HUB_BASE="${HUB_BASE:-https://api.matrixhub.io}"
SITE_URL="${SITE_URL:-https://matrixhub.io}"
TOKEN="${TOKEN:-}"
TIMEOUT_S="${TIMEOUT_S:-12}"
SKIP_HEALTH_CHECKS="${SKIP_HEALTH_CHECKS:-false}"

# --- Colors for output ---
C_RESET='\033[0m'
C_GREEN='\033[0;32m'
C_RED='\033[0;31m'
C_YELLOW='\033[0;33m'
C_CYAN='\033[0;36m'
C_BOLD='\033[1m'

# --- Build common querystring ---
# (This part is unchanged)
qs=()
qs+=("q=$(printf '%s' "$Q" | jq -s -R -r @uri)")
qs+=("limit=${LIMIT:-10}")
qs+=("offset=${OFFSET:-0}")
[[ -n "${TYPE:-}"       ]] && qs+=("type=$(printf '%s' "${TYPE}" | jq -s -R -r @uri)")
[[ -n "${CAPS:-}"       ]] && qs+=("caps=$(printf '%s' "${CAPS}" | jq -s -R -r @uri)")
[[ -n "${FRAMEWORKS:-}" ]] && qs+=("frameworks=$(printf '%s' "${FRAMEWORKS}" | jq -s -R -r @uri)")
[[ -n "${PROVIDERS:-}"  ]] && qs+=("providers=$(printf '%s' "${PROVIDERS}" | jq -s -R -r @uri)")
[[ -n "${SORT:-}"       ]] && qs+=("sort=$(printf '%s' "${SORT}" | jq -s -R -r @uri)")
[[ -n "${ORDER:-}"      ]] && qs+=("order=$(printf '%s' "${ORDER}" | jq -s -R -r @uri)")
QS="$(IFS='&'; echo "${qs[*]}")"

# --- Endpoints ---
HUB_HEALTH_URL="${HUB_BASE%/}/health"
HUB_READY_URL="${HUB_BASE%/}/ready"
HUB_SEARCH_URL="${HUB_BASE%/}/catalog/search?${QS}"
FRONTEND_SEARCH_URL="${SITE_URL%/}/api/search?${QS}"

# --- Helper functions ---
hr() { printf '%*s\n' "$(tput cols 2>/dev/null || echo 80)" '' | tr ' ' '-'; }

do_curl() {
  local label="$1" url="$2"
  
  hr
  echo -e "▶ ${C_CYAN}$label${C_RESET}"
  echo "URL: $url"
  echo "TIMEOUT: ${TIMEOUT_S}s"
  hr

  local hdr_auth=()
  if [[ -n "$TOKEN" ]]; then
    hdr_auth=(-H "Authorization: Bearer $TOKEN")
  fi

  local response
  response="$(curl -sS -L -m "$TIMEOUT_S" \
    -H 'Accept: application/json' "${hdr_auth[@]}" \
    -w "\n---METRICS_SEPARATOR---\n%{json}" \
    "$url" || true)"

  local body
  body="$(echo -e "$response" | sed '/^---METRICS_SEPARATOR---/,$d')"
  local metrics_json
  metrics_json="$(echo -e "$response" | sed -n '/^---METRICS_SEPARATOR---/,$p' | tail -n 1)"
  
  local http_code
  http_code="$(echo "$metrics_json" | jq -r '.http_code // "000"')"

  echo -e "${C_BOLD}--- response (truncated/pretty if jq present) ---${C_RESET}"
  if command -v jq >/dev/null 2>&1 && jq . >/dev/null 2>&1 <<< "$body"; then
      echo "$body" | jq . | head -n 80
  else
      echo "$body" | head -c 2048; echo
  fi
  
  echo
  echo -e "${C_BOLD}--- verdict ---${C_RESET}"
  case "$http_code" in
    2*) echo -e "${C_GREEN}OK: $http_code from $label${C_RESET}" ;;
    3*) echo -e "${C_YELLOW}REDIRECT: $http_code from $label (followed)${C_RESET}" ;;
    4*) echo -e "${C_RED}CLIENT ERROR: $http_code from $label${C_RESET}" ;;
    5*) echo -e "${C_RED}SERVER ERROR: $http_code from $label${C_RESET}" ;;
    *)  echo -e "${C_RED}FAIL: connection/timeout error to $label (curl code: $http_code)${C_RESET}" ;;
  esac

  echo
  echo -e "${C_BOLD}--- curl metrics (summary) ---${C_RESET}"
  if command -v jq >/dev/null 2>&1; then
    # Select only the most important fields for a clean summary
    echo "$metrics_json" | jq '{
      http_code,
      url_effective,
      remote_ip,
      num_redirects,
      time_total,
      time_namelookup,
      time_connect,
      time_starttransfer
    }'
  else
    echo "$metrics_json"
  fi
}

# --- Main execution ---
if [ "$SKIP_HEALTH_CHECKS" != "true" ]; then
  do_curl "Hub /health" "$HUB_HEALTH_URL"
  do_curl "Hub /ready"  "$HUB_READY_URL"
else
  echo "▶ Skipping health checks as requested."
fi

# Compare search (Hub direct vs Frontend proxy)
do_curl "Hub /catalog/search (direct)" "$HUB_SEARCH_URL"
do_curl "Frontend /api/search (proxy)" "$FRONTEND_SEARCH_URL"

echo
hr
echo "Done. If Hub direct returns 200 with results but Frontend proxy fails,"
echo "the issue is in the Vercel API route, networking, or envs."
echo "If both fail, it's backend/origin (Hub) or Cloudflare to origin."
hr