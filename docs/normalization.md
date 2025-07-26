# Normalization

Converts validated manifests into relational rows and auxiliary tables used by search & install.

## Canonical Identity

- **UID**: `"{type}:{id}@{version}"` (e.g., `agent:pdf-summarizer@1.4.2`)
- **Type**: `agent | tool | mcp_server`
- **Name** (display), **Summary**, **Description**, **License**, **Homepage**, **Source URL**

## Field Hygiene

- **Capabilities / Tags**: lowercase slug tokens, deduplicated.
- **Compatibility**: `frameworks`, `providers`, `runtime`, version ranges.
- **Artifacts**: `pypi | oci | git | zip` with `spec` JSON.
- **Adapters**: framework + `template_key` + optional path/params.
- **mcp_registration**: tool/server/resources/prompts blocks.

## Versioning

- Versions are strings; sorting is lexical unless catalog provides SemVer hints.
- We do **not** infer "latest" at write time; the **client** decides at read time.

## Rejection Reasons (examples)

- Schema violation: missing required fields.
- Policy violation: denied license.
- Unresolvable artifact: missing `package` or invalid `image`.
