#!/usr/bin/env bash
# Check a remote Matrix Hub catalog and report if it's effectively empty.
# Adds: side-by-side include_pending=false/true, CF header surfacing, timing,
# pending gateway count (if TOKEN provided), and optional frontend comparison.
#
# Usage:
#   chmod +x scripts/check_remote_hub.sh
#   scripts/check_remote_hub.sh
#
# Env vars (read from .env if present):
#   MATRIX_HUB_BASE  preferred base (e.g., https://api.matrixhub.io)
#   HUB_BASE         fallback base
#   SITE_URL         optional; if set, compare /api/search proxy
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
SITE_URL="${SITE_URL:-}"
TOKEN="${TOKEN:-}"
TIMEOUT_S="${TIMEOUT_S:-12}"

C_RESET='\033[0m'; C_BOLD='\033[1m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_CYAN='\033[0;36m'

hr(){ printf '%*s\n' "$(tput cols 2>/dev/null || echo 80)" '' | tr ' ' '-'; }
say(){ printf "%b\n" "$*"; }

auth_args=()
[[ -n "$TOKEN" ]] && auth_args=(-H "Authorization: Bearer $TOKEN")

curl_i() {
  # curl with headers (-i). Adds brief metrics JSON after body.
  local url="$1"; shift
  curl -sS -L -m "$TIMEOUT_S" -i \
    -H 'Accept: application/json' "${auth_args[@]}" "$@" "$url" \
    -w '\n---CURL_METRICS---\n{"http_code":%{http_code},"time_total":%{time_total},"time_starttransfer":%{time_starttransfer},"remote_ip":"%{remote_ip}","url":"%{url_effective}"}' \
    || true
}

just_body() {
  # Strip headers + metrics trailer
  sed -n '/^\r*$/,$p' | sed '1d' | sed '/^---CURL_METRICS---/,$d'
}

just_headers() {
  sed -n '1,/^\r*$/p'
}

just_metrics() {
  sed -n '/^---CURL_METRICS---/,$p' | tail -n 1 | sed 's/^---CURL_METRICS---//'
}

parse_json_field() {
  local json="$1" jqpath="$2"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r "$jqpath" 2>/dev/null || echo ""
  else
    echo ""
  fi
}

parse_total_from_url() {
  local url="$1"; shift
  local body
  body="$(curl -sS -L -m "$TIMEOUT_S" -H 'Accept: application/json' "${auth_args[@]}" "$@" "$url" || true)"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$body" | jq -r 'try .total // "unknown"'
  else
    local t
    t="$(printf '%s' "$body" | sed -n 's/.*"total"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n1)"
    [[ -n "$t" ]] && echo "$t" || echo "unknown"
  fi
}

show_block() {
  local title="$1" url="$2"
  hr; say "▶ ${C_CYAN}${title}${C_RESET} ${url}"
  local out; out="$(curl_i "$url")"
  local headers; headers="$(printf '%s' "$out" | just_headers)"
  local body; body="$(printf '%s' "$out" | just_body)"
  local metrics; metrics="$(printf '%s' "$out" | just_metrics)"
  local code; code="$(parse_json_field "$metrics" '.http_code')"

  # Summarize headers (CF, cache, etag)
  local cf_ray cf_cache etag lastmod
  cf_ray="$(printf '%s' "$headers" | awk 'BEGIN{IGNORECASE=1}/^CF-Ray:/{print $0}')"
  cf_cache="$(printf '%s' "$headers" | awk 'BEGIN{IGNORECASE=1}/^CF-Cache-Status:/{print $0}')"
  etag="$(printf '%s' "$headers" | awk 'BEGIN{IGNORECASE=1}/^ETag:/{print $0}')"
  lastmod="$(printf '%s' "$headers" | awk 'BEGIN{IGNORECASE=1}/^Last-Modified:/{print $0}')"

  echo "----- headers (key lines) -----"
  [[ -n "$cf_ray" ]] && echo "$cf_ray"
  [[ -n "$cf_cache" ]] && echo "$cf_cache"
  [[ -n "$etag" ]] && echo "$etag"
  [[ -n "$lastmod" ]] && echo "$lastmod"

  echo "----- body (pretty/truncated) -----"
  if command -v jq >/dev/null 2>&1 && jq . >/dev/null 2>&1 <<< "$body"; then
    echo "$body" | jq . | head -n 80
  else
    echo "$body" | head -c 2048; echo
  fi

  echo "----- metrics -----"
  if command -v jq >/dev/null 2>&1; then
    echo "$metrics" | jq .
  else
    echo "$metrics"
  fi

  # Verdict
  if [[ "$code" =~ ^2 ]]; then
    say "${C_GREEN}OK $code${C_RESET}"
  elif [[ "$code" == "524" ]]; then
    say "${C_YELLOW}Cloudflare 524: origin timeout (long-running task)${C_RESET}"
  elif [[ "$code" =~ ^5 ]]; then
    say "${C_RED}Server error $code${C_RESET}"
  else
    say "${C_YELLOW}HTTP $code${C_RESET}"
  fi
  echo
}

echo
say "🏷  Base: ${C_CYAN}${BASE}${C_RESET}"
[[ -n "$TOKEN" ]] && say "🔑 Using Bearer token from \$TOKEN"
[[ -n "$SITE_URL" ]] && say "🌐 Frontend: ${C_CYAN}${SITE_URL%/}${C_RESET}"

# --- Health ---
show_block "Health" "${BASE}/health"

# --- Config (ok if 404) ---
show_block "Config (OK if 404)" "${BASE}/config"

# --- Smoke search: limit=1 (no pending) ---
show_block "Search (smoke, include_pending=false)" "${BASE}/catalog/search?q=test&limit=1&include_pending=false"
t_smoke="$(parse_total_from_url "${BASE}/catalog/search" --get --data-urlencode q=test --data-urlencode limit=1 --data-urlencode include_pending=false)"
say "→ total(smoke, pending=false) = ${C_BOLD}${t_smoke}${C_RESET}"

# --- Smoke search: limit=1 (pending=true) ---
show_block "Search (smoke, include_pending=true)" "${BASE}/catalog/search?q=test&limit=1&include_pending=true"
t_smoke_p="$(parse_total_from_url "${BASE}/catalog/search" --get --data-urlencode q=test --data-urlencode limit=1 --data-urlencode include_pending=true)"
say "→ total(smoke, pending=true)  = ${C_BOLD}${t_smoke_p}${C_RESET}"

# --- CLI-like search ---
show_block "Search (CLI-like Slack, type=mcp_server, keyword, include_pending=true, limit=5)" \
  "${BASE}/catalog/search?q=Slack&type=mcp_server&mode=keyword&include_pending=true&limit=5"

# --- Mode sweep ---
for MODE in keyword semantic hybrid; do
  show_block "Search (mode=${MODE}, q=Slack, include_pending=true, limit=5)" \
    "${BASE}/catalog/search?q=Slack&mode=${MODE}&include_pending=true&limit=5"
done

# --- Pending gateways count (requires TOKEN) ---
if [[ -n "$TOKEN" ]]; then
  show_block "Gateways pending (limit=5)" "${BASE}/gateways/pending?limit=5&offset=0"
else
  hr; say "ℹ Skipping /gateways/pending (set TOKEN to query protected admin endpoints)"; echo
fi

# --- Optional: compare frontend proxy if SITE_URL present ---
if [[ -n "$SITE_URL" ]]; then
  FE="${SITE_URL%/}"
  show_block "Frontend /api/search (pending default via proxy)" "${FE}/api/search?q=Slack&limit=5"
  show_block "Frontend /api/search (pending=false override)"    "${FE}/api/search?q=Slack&limit=5&include_pending=false"
  show_block "Frontend /api/search (pending=true override)"     "${FE}/api/search?q=Slack&limit=5&include_pending=true"
fi

hr
say "Done."
hr
