#!/usr/bin/env bash
set -Eeuo pipefail

# Serve the repo and POST each manifest in examples/index.json (or local_index.json)
# to Matrix Hub's /catalog/install. Minimal and maintainable.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="${REPO_ROOT:-"$(cd "$SCRIPT_DIR/.." && pwd)"}"

# --- env (optional) ---
if [[ -z "${ENV_FILE:-}" ]]; then
  CANDIDATE="$REPO_ROOT/.env"
  [[ -f "$CANDIDATE" ]] && ENV_FILE="$CANDIDATE"
fi
if [[ -n "${ENV_FILE:-}" && -f "$ENV_FILE" ]]; then
  echo "ℹ️  Loading .env from $ENV_FILE"
  set +u; set -a; source "$ENV_FILE"; set +a; set -u
fi

# --- Config ---
HUB_URL="${HUB_URL:-${MATRIX_HUB_URL:-http://127.0.0.1:443}}"; HUB_URL="${HUB_URL%/}"
HUB_TOKEN="${HUB_TOKEN:-${MATRIX_HUB_TOKEN:-}}"
SERVE_DIR="${SERVE_DIR:-$REPO_ROOT}"
SERVE_HOST="${SERVE_HOST:-127.0.0.1}"
SERVE_PORT="${SERVE_PORT:-8000}"
INDEX_PATH_REL="${INDEX_PATH_REL:-examples/index.json}"
[[ ! -f "$SERVE_DIR/${INDEX_PATH_REL#/}" && -f "$SERVE_DIR/examples/local_index.json" ]] && INDEX_PATH_REL="examples/local_index.json"
INDEX_PATH_REL="${INDEX_PATH_REL#/}"
INDEX_URL="http://${SERVE_HOST}:${SERVE_PORT}/${INDEX_PATH_REL}"
TARGET_DIR="${TARGET_DIR:-./}"

need(){ command -v "$1" >/dev/null 2>&1 || { echo "✖ $1 is required"; exit 1; }; }
need jq; need curl; need python

norm_auth(){ local t="${1:-}"; [[ -z "$t" ]] && { echo ""; return; }; [[ "$t" =~ ^([Bb]earer|[Bb]asic)\  ]] && echo "$t" || echo "Bearer $t"; }

port_in_use(){ python - "$SERVE_HOST" "$1" <<'PY'
import socket, sys
h, p = sys.argv[1], int(sys.argv[2])
s= socket.socket(); s.settimeout(0.3)
try:
  s.connect((h,p)); print('1')
except Exception:
  print('0')
finally:
  s.close()
PY
}

# Pick a free port quickly (8000..8020)
if [[ "$(port_in_use "$SERVE_PORT")" == "1" ]]; then
  for p in $(seq 8000 8020); do
    if [[ "$(port_in_use "$p")" == "0" ]]; then SERVE_PORT="$p"; break; fi
  done
  INDEX_URL="http://${SERVE_HOST}:${SERVE_PORT}/${INDEX_PATH_REL}"
fi

# Hub TLS autodetect on :443
HUB_CURL_OPTS=()
if [[ "$HUB_URL" =~ ^https?://127\.0\.0\.1:443$ ]]; then
  if curl -k -sS -I --max-time 2 "https://127.0.0.1:443/health" >/dev/null 2>&1; then
    HUB_URL="https://127.0.0.1:443"; HUB_CURL_OPTS=(-k)
  else
    HUB_URL="http://127.0.0.1:443"
  fi
fi
[[ "$HUB_URL" == https:* ]] && HUB_CURL_OPTS=(-k)
[[ -n "${HUB_TOKEN:-}" ]] && HUB_AUTH=(-H "Authorization: $(norm_auth "$HUB_TOKEN")") || HUB_AUTH=()

# Index must exist on disk
[[ -f "$SERVE_DIR/${INDEX_PATH_REL#/}" ]] || { echo "✖ Missing index: $SERVE_DIR/${INDEX_PATH_REL#/}"; exit 1; }

# Start static server
pushd "$SERVE_DIR" >/dev/null
python -m http.server "$SERVE_PORT" --bind "$SERVE_HOST" >/dev/null 2>&1 &
SERVER_PID=$!
popd >/dev/null
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT

echo "▶️  Serving $SERVE_DIR at http://$SERVE_HOST:$SERVE_PORT/"

# Wait index
for i in {1..60}; do
  code="$(curl -sS -w '%{http_code}' -o /dev/null "$INDEX_URL" || true)"
  [[ "$code" =~ ^2..$ ]] && { echo "✔ Index ready ($INDEX_URL)"; break; }
  (( i==60 )) && { echo "✖ Index not reachable ($INDEX_URL)"; exit 1; }
  sleep 0.25
done

INDEX_JSON="$(curl -fsSL "$INDEX_URL")"

# Extract manifest refs (relative OK)
mapfile -t MANIFESTS < <(jq -r '
  if (.manifests|type=="array") then .manifests[]
  elif (.items|type=="array") then .items[].manifest_url
  elif (.entries|type=="array") then (.entries[] | ( (.base_url//"") + (.path//"") ))
  else empty end' <<<"$INDEX_JSON")
[[ ${#MANIFESTS[@]} -gt 0 ]] || { echo "✖ No manifest refs in index"; exit 1; }

# Resolve and process each manifest
resolve(){ python - "$INDEX_URL" "$1" <<'PY'
import sys
from urllib.parse import urlparse, urljoin
base, ref = sys.argv[1].strip(), sys.argv[2].strip()
if not ref or ref == 'null':
  print(''); raise SystemExit
if ref.startswith(('http://','https://')):
  print(ref); raise SystemExit
p = urlparse(base); root = f"{p.scheme}://{p.netloc}/"
print(urljoin(root, ref.lstrip('/')))
PY
}

for RAW in "${MANIFESTS[@]}"; do
  MURL="$(resolve "$RAW")"; [[ -z "$MURL" ]] && { echo "• skip blank ref"; continue; }
  # If the ref targets localhost with a different port, rewrite to our effective port
  MURL="$(python - "$MURL" "$SERVE_HOST" "$SERVE_PORT" <<'PY'
import sys
from urllib.parse import urlparse, urlunparse
u, host, port = sys.argv[1], sys.argv[2], sys.argv[3]
p = urlparse(u)
if p.hostname in {host,'127.0.0.1','localhost','0.0.0.0'} and (p.port and str(p.port)!=port):
  p = p._replace(scheme='http', netloc=f"{host}:{port}")
print(urlunparse(p))
PY
)"

  echo "▶️  Fetch $MURL"
  MANIFEST="$(curl -fsSL "$MURL" || true)"; [[ -z "$MANIFEST" ]] && { echo "   ✖ fetch failed"; continue; }

  BASE="$(jq -r '.mcp_registration.server.url // empty' <<<"$MANIFEST")"; [[ -z "$BASE" ]] && { echo "   ⚠ no server.url"; continue; }
  BASE="${BASE%/}"; SSE="${BASE}/sse"

  PATCHED="$(jq --arg url "$SSE" '.mcp_registration.server.url=$url | del(.mcp_registration.server.transport)' <<<"$MANIFEST")"

  # Use a non-reserved variable name (avoid UID)
  ENTITY_UID="$(jq -r '"\(.type):\(.id)@\(.version)"' <<<"$MANIFEST")"
  echo "   📦 Install $ENTITY_UID → $HUB_URL/catalog/install"
  code="$(curl -sS -w '%{http_code}' -o /dev/null "$HUB_URL/catalog/install" \
     "${HUB_CURL_OPTS[@]}" "${HUB_AUTH[@]}" -H 'Content-Type: application/json' \
     -d "$(jq -nc --arg id "$ENTITY_UID" --arg target "$TARGET_DIR" --argjson manifest "$PATCHED" '{id:$id,target:$target,manifest:$manifest}')" || true)"
  [[ "$code" =~ ^2..$ ]] && echo "   ✅ ok (HTTP $code)" || echo "   ✖ failed (HTTP $code)"
done

echo "✅ Done."
