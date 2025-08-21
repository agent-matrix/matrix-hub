#!/usr/bin/env bash
# tests/test_search.sh — Matrix Hub search diagnostics
#
# What it checks:
#   1) /health and optional /config
#   2) /catalog/search reachability
#   3) Keyword / Semantic / Hybrid across multiple query variants
#   4) Tests both a PRIMARY type (e.g., mcp_server) and an OPTIONAL SECONDARY type (e.g., tool)
#   5) include_pending switch (important for new/derived entities)
#   6) ETag behavior
#   7) Optional DB peek (if sqlite3 + DB_PATH provided)
#
# Env (override as needed):
#   HUB_URL=http://127.0.0.1:443
#   API_TOKEN=...
#   QUERY="Hello World"
#   TYPE=mcp_server              # primary type to test
#   TYPE2=tool                   # optional 2nd type to test (leave empty to skip)
#   LIMIT=5
#   WITH_RAG=false
#   INCLUDE_PENDING=true
#   DEBUG=0
#   DB_PATH=./data/catalog.sqlite

set -euo pipefail

HUB_URL="${HUB_URL:-http://127.0.0.1:443}"
API_TOKEN="${API_TOKEN:-}"
QUERY="${QUERY:-Hello World}"
TYPE="${TYPE:-mcp_server}"
TYPE2="${TYPE2:-tool}"
LIMIT="${LIMIT:-5}"
WITH_RAG="${WITH_RAG:-false}"
INCLUDE_PENDING="${INCLUDE_PENDING:-true}"
DEBUG="${DEBUG:-0}"
DB_PATH="${DB_PATH:-}"

have() { command -v "$1" >/dev/null 2>&1; }
die()  { printf "\033[1;31m✖\033[0m %s\n" "$*" >&2; exit 1; }
ok()   { printf "\033[1;32m✔\033[0m %s\n" "$*"; }
info() { printf "\033[1;34m➜\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m!\033[0m %s\n" "$*"; }

have curl || die "curl is required"
have jq   || die "jq is required"

auth_flags=()
[[ -n "$API_TOKEN" ]] && auth_flags=(-H "Authorization: Bearer ${API_TOKEN}")

# Show useful flags/assumptions up front
echo "── Search test config ─────────────────────────────────────────────"
echo " HUB_URL           : $HUB_URL"
echo " QUERY             : $QUERY"
echo " TYPE              : $TYPE"
[[ -n "$TYPE2" ]] && echo " TYPE2             : $TYPE2" || true
echo " LIMIT             : $LIMIT"
echo " WITH_RAG          : $WITH_RAG"
echo " INCLUDE_PENDING   : $INCLUDE_PENDING"
echo " DEBUG             : $DEBUG"
[[ -n "$DB_PATH" ]] && echo " DB_PATH           : $DB_PATH"
echo "───────────────────────────────────────────────────────────────────"
echo

# --- timing output (single -w string when DEBUG=1) ----------------------------
_curl_writeout_format='%{http_code}\n
time_namelookup:   %{time_namelookup}
time_connect:      %{time_connect}
time_appconnect:   %{time_appconnect}
time_starttransfer:%{time_starttransfer}
time_total:        %{time_total}\n'

# --- robust GET with timeouts -------------------------------------------------
http_get() {
  local path="$1"; shift
  local headers_tmp body_tmp code
  headers_tmp="$(mktemp)"; body_tmp="$(mktemp)"
  local data_args=()
  for kv in "$@"; do data_args+=(--data-urlencode "$kv"); done
  local writeout_opt=()
  if [[ "${DEBUG}" == "1" ]]; then
    writeout_opt=(-w "$_curl_writeout_format")
  fi
  # shellcheck disable=SC2086
  curl -sS -G \
    "${HUB_URL%/}${path}" \
    -D "$headers_tmp" \
    -o "$body_tmp" \
    "${auth_flags[@]}" \
    -H "accept: application/json" \
    --connect-timeout 2 \
    --max-time 8 \
    --retry 0 \
    --max-redirs 2 \
    "${data_args[@]}" \
    "${writeout_opt[@]}" \
    >/dev/null || {
      echo "$headers_tmp|$body_tmp|000"
      return 99
    }
  code="$(awk 'NR==1{print $2}' "$headers_tmp")"
  echo "$headers_tmp|$body_tmp|$code"
}

print_top() {
    local body="$1" label="$2"
    local n total
    n="$(jq -r '.items | length' "$body" 2>/dev/null || echo 0)"
    total="$(jq -r '.total // (.items|length)' "$body" 2>/dev/null || echo "$n")"
    echo "  items: $n  total: $total  (${label})"
    if (( n > 0 )); then
        jq -r '
          .items[:5][] |
          {
            id, type, name, version,
            score_final,
            score_lexical,
            score_semantic,
            score_quality,
            score_recency,
            fit_reason
          } |
          "   • \(.id) (name=\(.name // "\"\""), v=\(.version // "\"\""), final=\(.score_final // "n/a"), lex=\(.score_lexical // "n/a"), sem=\(.score_semantic // "n/a"))" +
          (if .fit_reason then "\n     ↳ reason: " + (.fit_reason | tostring) else "" end)
        ' "$body"
    else
        echo "  (no items returned)"
        if [[ "${DEBUG}" == "1" ]]; then
            echo "  [DEBUG] raw response:"; sed -n '1,200p' "$body"
        fi
    fi
}

probe_endpoint() {
  local path="$1" label="$2"
  local h b c out
  out="$(http_get "$path")" || true
  IFS='|' read -r h b c <<<"$out"
  if [[ "$c" == "200" ]]; then
    echo "  ${label}: 200 OK"
    [[ "${DEBUG}" == "1" ]] && { echo "  [DEBUG] headers:"; sed -n '1,40p' "$h"; echo "  [DEBUG] body (first 80 lines):"; sed -n '1,80p' "$b"; }
  elif [[ "$c" == "404" || "$c" == "405" ]]; then
    echo "  ${label}: ${c} (not exposed); continuing"
  elif [[ "$c" == "000" ]]; then
    echo "  ${label}: timeout/connection error; continuing"
  else
    echo "  ${label}: ${c}"
    [[ "${DEBUG}" == "1" ]] && sed -n '1,40p' "$h"
  fi
  rm -f "$h" "$b"
}

print_headers_if_debug() {
  local headers="$1"
  if [[ "${DEBUG}" == "1" ]]; then
    echo "[DEBUG] Response headers:"
    sed -n '1,40p' "$headers"
  fi
}

# --- 0) Health/config probes --------------------------------------------------
info "Probing optional /health and /config (if exposed)…"
probe_endpoint "/health" "GET /health"
probe_endpoint "/config" "GET /config"
echo

# --- 1) Reachability ----------------------------------------------------------
info "Ping /catalog/search (connectivity)…"
out="$(http_get "/catalog/search" "q=test" "limit=1")" || die "Search endpoint not reachable"
IFS='|' read -r h0 b0 c0 <<<"$out"
print_headers_if_debug "$h0"
if [[ "$c0" != "200" && "$c0" != "304" ]]; then
  warn "Unexpected status: $c0"
  sed -n '1,30p' "$h0"
  die "search did not return 200/304"
fi
ok "Search reachable (${c0})"
rm -f "$h0" "$b0"
echo

# Helpers for alternate queries

to_underscore() { echo "$1" | tr ' ' '_' | tr '-' '_' ; }

to_hyphen()     { echo "$1" | tr ' ' '-' | tr '_' '-' ; }

first_token()   { echo "$1" | awk '{print $1}'; }

Q1="$QUERY"
Q2="$(to_underscore "$QUERY")"
Q3="$(to_hyphen     "$QUERY")"
Q4="$(first_token   "$QUERY")"

run_mode_suite() {
  local typ="$1"; shift
  local label_suffix="$1"; shift

  # --- Keyword mode ----------------------------------------------------------
  for q in "$Q1" "$Q2" "$Q3" "$Q4"; do
    info "Keyword-only: q='${q}', type='${typ}', include_pending=${INCLUDE_PENDING}, limit=${LIMIT} ${label_suffix}"
    out="$(http_get "/catalog/search" "q=${q}" "type=${typ}" "mode=keyword" "limit=${LIMIT}" "with_rag=false" "include_pending=${INCLUDE_PENDING}")" || die "keyword request failed"
    IFS='|' read -r h b c <<<"$out"
    print_headers_if_debug "$h"
    if [[ "$c" != "200" ]]; then
      warn "Status: $c"; sed -n '1,30p' "$h"; die "keyword search failed"
    fi
    print_top "$b" "mode=keyword"
    ETAG1="$(grep -i '^ETag:' "$h" | awk '{print $2}' | tr -d '\r' || true)"
    [[ -n "${ETAG1:-}" ]] && echo "  etag: $ETAG1"
    echo
    rm -f "$h" "$b"
  done

  # --- Semantic mode ---------------------------------------------------------
  for q in "$Q1" "$Q2" "$Q3" "$Q4"; do
    info "Semantic-only: q='${q}', type='${typ}', include_pending=${INCLUDE_PENDING}, limit=${LIMIT} ${label_suffix}"
    out="$(http_get "/catalog/search" "q=${q}" "type=${typ}" "mode=semantic" "limit=${LIMIT}" "with_rag=false" "include_pending=${INCLUDE_PENDING}")" || die "semantic request failed"
    IFS='|' read -r h b c <<<"$out"
    print_headers_if_debug "$h"
    if [[ "$c" != "200" ]]; then
      warn "Status: $c"; sed -n '1,30p' "$h"; die "semantic search failed"
    fi
    print_top "$b" "mode=semantic"
    echo
    rm -f "$h" "$b"
  done

  # --- Hybrid + optional RAG -------------------------------------------------
  info "Hybrid (with_rag=${WITH_RAG}): q='${Q1}', type='${typ}', include_pending=${INCLUDE_PENDING}, limit=${LIMIT} ${label_suffix}"
  out="$(http_get "/catalog/search" "q=${Q1}" "type=${typ}" "mode=hybrid" "limit=${LIMIT}" "with_rag=${WITH_RAG}" "include_pending=${INCLUDE_PENDING}")" || die "hybrid request failed"
  IFS='|' read -r h b c <<<"$out"
  print_headers_if_debug "$h"
  if [[ "$c" != "200" ]]; then
    warn "Status: $c"; sed -n '1,30p' "$h"; die "hybrid search failed"
  fi
  print_top "$b" "mode=hybrid, rag=${WITH_RAG}"
  echo
  rm -f "$h" "$b"
}

# Run for primary TYPE
run_mode_suite "$TYPE" "(PRIMARY)"

# Optionally run for TYPE2 (e.g., tool) — useful after DERIVE_TOOLS_FROM_MCP=true installs
if [[ -n "$TYPE2" ]]; then
  run_mode_suite "$TYPE2" "(SECONDARY)"
fi

# --- 5) ETag test -------------------------------------------------------------
if [[ -n "${ETAG1:-}" ]]; then
  info "ETag test (If-None-Match)…"
  headers_tmp="$(mktemp)"; body_tmp="$(mktemp)"
  curl -sS -G \
    "${HUB_URL%/}/catalog/search" \
    -D "$headers_tmp" \
    -o "$body_tmp" \
    "${auth_flags[@]}" \
    -H "accept: application/json" \
    -H "If-None-Match: ${ETAG1}" \
    --data-urlencode "q=${Q1}" \
    --data-urlencode "type=${TYPE}" \
    --data-urlencode "mode=keyword" \
    --data-urlencode "limit=${LIMIT}" \
    --data-urlencode "with_rag=false" \
    --data-urlencode "include_pending=${INCLUDE_PENDING}" \
    --connect-timeout 2 \
    --max-time 8 \
    --retry 0 \
    --max-redirs 2 \
    >/dev/null || {
      rm -f "$headers_tmp" "$body_tmp"; die "etag request failed";
    }
  code="$(awk 'NR==1{print $2}' "$headers_tmp")"
  if [[ "$code" == "304" ]]; then
    ok "ETag honored (304 Not Modified)"
  else
    warn "Expected 304, got $code (cache may be off; not fatal)."
    [[ "${DEBUG}" == "1" ]] && { echo "[DEBUG] headers:"; sed -n '1,40p' "$headers_tmp"; }
  fi
  rm -f "$headers_tmp" "$body_tmp"
else
  warn "No ETag observed; skipping If-None-Match test."
fi

# --- 6) Optional: DB peek -----------------------------------------------------
if [[ -n "${DB_PATH}" && -f "${DB_PATH}" ]] && have sqlite3; then
  info "DB peek (entity counts by type) — ${DB_PATH}"
  sqlite3 -cmd ".mode tabs" -header "${DB_PATH}" \
    "SELECT type, COUNT(*) as count FROM entity GROUP BY type ORDER BY count DESC;" \
      | column -t -s $'\t' || warn "sqlite query failed"
  echo
  info "Last 5 ingested mcp_server names:"
  sqlite3 -cmd ".mode tabs" -header "${DB_PATH}" \
    "SELECT name, uid, datetime(created_at) as created_at
      FROM entity WHERE type='mcp_server'
      ORDER BY created_at DESC
      LIMIT 5;" | column -t -s $'\t' || true

  if [[ "$TYPE2" == "tool" ]]; then
    echo
    info "Last 5 derived tools:"
    sqlite3 -cmd ".mode tabs" -header "${DB_PATH}" \
      "SELECT name, uid, datetime(created_at) as created_at
        FROM entity WHERE type='tool'
        ORDER BY created_at DESC
        LIMIT 5;" | column -t -s $'\t' || true
  fi
fi

# --- Summary ------------------------------------------------------------------

echo
ok "Search diagnostics complete."
echo "  HUB_URL:           ${HUB_URL}"
echo "  QUERY:             ${QUERY}"
echo "  TYPE:              ${TYPE}"
[[ -n "$TYPE2" ]] && echo "  TYPE2:             ${TYPE2}" || true
echo "  LIMIT:             ${LIMIT}"
echo "  WITH_RAG:          ${WITH_RAG}"
echo "  INCLUDE_PENDING:   ${INCLUDE_PENDING}"
echo "  DEBUG:             ${DEBUG}"
[[ -n "${DB_PATH}" ]] && echo "  DB_PATH:           ${DB_PATH}"
