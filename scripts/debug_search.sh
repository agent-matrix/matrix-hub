# from repo root
python scripts/debug_search.py --q "hello-sse-server" --mode keyword --include-pending --limit 5 --backend none

# force pg_trgm path (if available)
python scripts/debug_search.py --q "hello-sse-server" --mode keyword --include-pending --limit 5 --backend pgtrgm

# try exact UID
python scripts/debug_search.py --q "mcp_server:hello-sse-server@0.1.0" --include-pending --backend none
