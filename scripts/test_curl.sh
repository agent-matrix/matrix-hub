# Health & optional config
curl -i "http://localhost:443/health"
curl -i "http://localhost:443/config"  # ok if 404

# Basic reachability (expect 200 with empty/short payload)
curl -sS -G "http://localhost:443/catalog/search" \
  --data-urlencode "q=test" \
  --data-urlencode "limit=1" -i

# Primary check aligned with CLI defaults
curl -sS -G "http://localhost:443/catalog/search" \
  --data-urlencode "q=Hello World" \
  --data-urlencode "type=mcp_server" \
  --data-urlencode "mode=keyword" \
  --data-urlencode "include_pending=true" \
  --data-urlencode "limit=5" -i

# Try “any” (omit type filter), and switch modes
for MODE in keyword semantic hybrid; do
  curl -sS -G "http://localhost:443/catalog/search" \
    --data-urlencode "q=Hello" \
    --data-urlencode "mode=$MODE" \
    --data-urlencode "limit=5" \
    --data-urlencode "include_pending=true" -i
done
