# Chunking

Prepares text for semantic search & RAG.

## Inputs

- `name`, `summary`, `description`
- README/excerpts referenced by manifest or repository
- Examples / usage snippets (if provided)

## Strategy

- **Hierarchical splitting**:
  1. Headings (`#`, `##`) → paragraphs → sentences
  2. Target chunk size ~ **300–600 tokens** (configurable)
- **Metadata** per chunk:
  - `entity_uid`, `section`, `position`, `weight`, `source_uri`, `checksum`

## Weights

- Title/name: higher prior (e.g., 1.3×)
- Summary: 1.2×
- README/body: 1.0×
- Examples/code: 1.1×

## Output

- A list of `(chunk_id, entity_uid, text, weight, meta)` ready for embedding.
