# Matrix Hub — Top‑5 Search API

This document defines the **public, production‑safe** search endpoint that powers the Matrix Hub meta search for agents, tools, and MCP servers. The contract is **additive** and **backward‑compatible** with existing deployments.

---

## Endpoint

`GET /catalog/search`

### Purpose

Return the **Top‑5** best matches for a user query across `agent`, `tool`, and `mcp_server` entities.

### Query Parameters

| Name            | Type                                  | Default        | Description                                                                                      |
| --------------- | ------------------------------------- | -------------- | ------------------------------------------------------------------------------------------------ |
| `q`             | string                                | **required**   | The user intent. Example: `summarize pdfs`                                                       |
| `type`          | enum (`agent\|tool\|mcp_server\|any`) | `any`          | Filter by entity type. `any` means no filter.                                                    |
| `limit`         | integer (1–100)                       | `5`            | Maximum results returned. Public API caps to **5** even if larger is requested.                  |
| `with_snippets` | boolean                               | `false`        | Include a short snippet (first \~200 chars of summary/description) in each item, when available. |
| `mode`          | enum (`keyword\|semantic\|hybrid`)    | server default | Advanced: controls which backends participate.                                                   |
| `with_rag`      | boolean                               | `false`        | Advanced: include an optional `fit_reason` field per item.                                       |
| `rerank`        | enum (`none\|llm`)                    | server default | Advanced: apply an LLM reranker to the merged results.                                           |

> **Note:** Additional filtering parameters exist (`capabilities`, `frameworks`, `providers`). They accept CSV values.

---

## Response Shape

```json
{
  "items": [
    {
      "id": "tool:hello@0.1.0",
      "type": "tool",
      "name": "hello",
      "version": "0.1.0",
      "summary": "Return greeting",
      "capabilities": ["hello"],
      "frameworks": ["example"],
      "providers": ["self"],

      "score_lexical": 0.81,
      "score_semantic": 0.74,
      "score_quality": 0.90,
      "score_recency": 0.88,
      "score_final": 0.82,

      "fit_reason": null,

      "manifest_url": "https://…/hello.manifest.json",
      "install_url": "https://api.matrixhub.io/catalog/install?id=tool:hello@0.1.0",
      "snippet": "Short summary snippet if with_snippets=true"
    }
  ],
  "total": 1
}
```

### Field Notes

* `manifest_url` comes from the entity’s `source_url` when present; otherwise it may point to a local resolver `GET /catalog/manifest/{id}`.
* `install_url` is a convenience link; clients should still `POST /catalog/install` under the hood.
* `snippet` appears only if `with_snippets=true` and summary/description text exists.
* `total` is a conservative estimate of distinct entities matched by the underlying backends.

---

## Example

Search for the top‑5 items related to extracting tables from PDFs, across all types:

```bash
curl -s 'https://api.matrixhub.io/catalog/search?q=extract%20pdf%20tables&type=any&limit=5&with_snippets=true' | jq
```

---

## Install

Once you select an item from the results, install it via the canonical install endpoint:

```bash
curl -s -X POST 'https://api.matrixhub.io/catalog/install' \
  -H 'Content-Type: application/json' \
  -d '{
    "id": "tool:pdf_table_extractor@1.1.0",
    "target": "./"
  }'
```

You may also install from an inline manifest by providing a `manifest` object in the body.

---

## Compatibility & Stability

* This API is **additive**; existing clients continue to work.
* No database migrations are required for this feature.
* Works in SQLite (dev) and Postgres (prod). Semantic search via pgvector can be enabled later without changing the contract.
