# Watsonx MCP Agent (SSE)

This is an MCP server that exposes a `chat` tool over **SSE** at `/sse`.

## Prereqs

- Python 3.11+
- In this folder:
  - `server.py` (your agent)
  - `requirements.txt`
  - `runner.json` (added)
  - `.env` (copy from `.env.example` and fill in your creds)

Install deps:

```bash
python -m venv .venv
source .venv/bin/activate
pip install -U pip
pip install -r requirements.txt
````

Create `.env`:

```bash
cp .env.example .env
# edit the file and add your watsonx creds
```

## Use with Matrix CLI

Link this folder as an alias (so Matrix knows how to start it):

```bash
# from this folder
matrix link --alias watsonx-agent .
```

Run it:

```bash
matrix run watsonx-agent
```

Check it’s running:

```bash
matrix ps
# URL column should show: http://127.0.0.1:<PORT>/sse
```

Probe and call via MCP:

```bash
matrix mcp probe --alias watsonx-agent
matrix mcp call chat --alias watsonx-agent --args '{"query":"hello"}'
```

Tail logs:

```bash
matrix logs watsonx-agent -f
```

Stop:

```bash
matrix stop watsonx-agent
```

Uninstall (optional):

```bash
matrix uninstall watsonx-agent --purge -y
```

```

---

# Notes / Why this works

- Your `server.py` already uses **FastMCP** and runs **SSE** at `/sse`.  
  We simply tell the Matrix runtime that:
  - it should run `python server.py`,
  - it must inject a port (`PORT` & `WATSONX_AGENT_PORT`),
  - and that the MCP endpoint is `/sse`.

- `matrix ps` will show a **URL** column, built from host+port+endpoint it finds in `runner.json`.  
  With the file above, it’ll show something like:
```

[http://127.0.0.1:54047/sse](http://127.0.0.1:54047/sse)

```

- `matrix mcp probe --alias watsonx-agent` auto-discovers the port from `ps`, then calls `/sse`.  
You can also use the URL directly:
```

matrix mcp probe --url [http://127.0.0.1:54047/sse](http://127.0.0.1:54047/sse)

```

- Your tool function is named **`chat`**, so:
```

matrix mcp call chat --alias watsonx-agent --args '{"query":"hello"}'
