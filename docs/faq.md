# FAQ

**Q: Can I run Matrix Hub without Postgres?** Yes, for local development and tests. Some search features (pg_trgm/pgvector) are unavailable on SQLite.

**Q: Where do adapter files go?** They’re written under your target project directory (e.g., `src/flows/...`) and referenced in `matrix.lock.json`.

**Q: How do I add my agents/tools to the catalog?** Publish manifests in your catalog repo and ensure they’re listed in its `index.json`. Then configure that index URL in `MATRIX_REMOTES`.

**Q: Does Matrix Hub modify MCP Gateway code?** No. It uses gateway admin APIs to register tools/servers.

**Q: How do I update an installed agent?** Re-run `POST /catalog/install` with the new `id@version`. Your lockfile is updated and registrations are refreshed.
