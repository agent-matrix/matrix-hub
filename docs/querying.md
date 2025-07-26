# Querying API

Matrix Hub exposes `GET /catalog/search` for discovery with optional hybrid ranking and RAG.

## Endpoint

`GET /catalog/search`

### Query Parameters

- `q` *(required)*: free-text query
- `type`: `agent | tool | mcp_server`
- `capabilities`: CSV (`pdf,summarize`)
- `frameworks`: CSV (`langgraph,watsonx_orchestrate`)
- `providers`: CSV (`openai,watsonx`)
- `mode`: `keyword | semantic | hybrid` (default from settings)
- `limit`: default 20
- `offset`: default 0
- `with_rag`: `true|false`
- `rerank`: `none | llm` (future)
- `etag`: handled via `If-None-Match` header

### Response (shape)

```json
{
  "items": [
    {
      "id": "agent:pdf-summarizer@1.4.2",
      "type": "agent",
      "name": "PDF Summarizer",
      "version": "1.4.2",
      "summary": "Summarizes long PDFs.",
      "capabilities": ["pdf", "summarize"],
      "frameworks": ["langgraph"],
      "providers": ["watsonx"],
      "score_lexical": 0.81,
      "score_semantic": 0.74,
      "score_quality": 0.90,
      "score_recency": 0.88,
      "score_final": 0.82,
      "fit_reason": "Matches 'summarize pdfs' in README."
    }
  ],
  "total": 1
}
```

### Examples
```bash
# Keyword-only
curl -s 'http://localhost:7300/catalog/search?q=pdf&type=agent&mode=keyword' | jq

# Hybrid with filters and RAG
curl -s 'http://localhost:7300/catalog/search?q=summarize%20pdfs&type=agent&capabilities=pdf,summarize&mode=hybrid&with_rag=true' | jq
```
