# Installing Agents/Tools via Matrix Hub

You can install through the **CLI** or the **API**. Installation computes a plan, executes artifacts (pip/uv, docker, git, zip), writes adapters, registers to MCP Gateway, and emits `matrix.lock.json`.

## CLI

```bash
# Search
matrix search "summarize pdfs" --type agent --capabilities pdf,summarize

# Install into your project
matrix install agent:pdf-summarizer@1.4.2 --target ./apps/pdf-bot
```

## API
```bash
curl -s -X POST 'http://localhost:7300/catalog/install' \
  -H 'Content-Type: application/json' \
  -d '{"id":"agent:pdf-summarizer@1.4.2","target":"./apps/pdf-bot"}' | jq
```

## Artifacts Supported
- `pypi` → `uv pip install …` (fallback to `pip`)
- `oci` → `docker pull …`
- `git` → `git clone …` (+ optional checkout)
- `zip` → `curl + unzip`

## Adapters
Framework glue written to your project (e.g., LangGraph node).
Path defaults can be overridden per adapter spec.
Files added to `matrix.lock.json` under `adapters_files`.

## Lockfile
`matrix.lock.json` records installed entities, artifacts, digests, and adapters for reproducibility.

## Rollback (manual)
Remove adapters and revert project changes.
Re-run install with a known-good version (`@version`).
