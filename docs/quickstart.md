# Quickstart

## Requirements
- Docker 24+ with docker compose
- Or Python 3.11/3.12 for local dev

## 1) Clone and configure

```bash
git clone https://github.com/agent-matrix/matrix-hub.git
cd matrix-hub
cp .env.example .env
```
Edit `.env` as needed (e.g., `MATRIX_REMOTES` to your catalog’s `index.json`).

## 2) Run with compose
```bash
docker compose up -d --build
curl -s http://localhost:7300/health | jq
```
Expected:

```json
{ "status": "ok" }
```

## 3) Search the catalog
```bash
curl -s 'http://localhost:7300/catalog/search?q=summarize%20pdfs&type=agent&capabilities=pdf,summarize' | jq
```

## 4) Install into your project
```bash
mkdir -p apps/pdf-bot
curl -s -X POST 'http://localhost:7300/catalog/install' \
  -H 'Content-Type: application/json' \
  -d '{"id":"agent:pdf-summarizer@1.4.2","target":"./apps/pdf-bot"}' | jq
```
This writes project adapters and `apps/pdf-bot/matrix.lock.json`.

If the manifest includes `mcp_registration`, the installer also registers the tool/server with MCP Gateway.

## 5) Local development (no Docker)
```bash
python -m venv .venv && source .venv/bin/activate
pip install -U pip
pip install -e .
make dev
```
# open http://localhost:7300/health
