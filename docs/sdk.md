# Python SDK (matrix-python-sdk)

The SDK provides a small client for Matrix Hub APIs, used by both the CLI and the agent generator.

## Install

```bash
pip install matrix-python-sdk
```
## Usage
```python
from matrix_sdk.client import MatrixClient

client = MatrixClient(base_url="http://localhost:7300", token=None)

# Search
resp = client.search(
    q="summarize pdfs",
    type="agent",
    capabilities="pdf,summarize",
    limit=5
)
for item in resp["items"]:
    print(item["id"], item["score_final"])

# Show entity
entity = client.entity("agent:pdf-summarizer@1.4.2")

# Install
install = client.install("agent:pdf-summarizer@1.4.2", target="./apps/pdf-bot")
print(install["files_written"])
```

## Timeouts & Retries
Default timeout: 20s (configurable per client).
Retries handled by the CLI for network hiccups; the server is idempotent.

## Auth
If `API_TOKEN` is set on the server, pass a Bearer token:
```python
MatrixClient(base_url=..., token="your-api-token")
```
