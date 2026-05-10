# TODO — next session

## Status snapshot (2026-05-09)

`https://www.matrixhub.io/status` is fully green:

| Row       | State                                  |
| --------- | -------------------------------------- |
| API       | **Operational** (`api.matrixhub.io`)   |
| Database  | **Connected** (Aiven Postgres 17)      |
| Frontend  | **Operational** (Next.js on Vercel)    |
| Catalog   | **7466 items** indexed                 |

The only remaining bug:

> `https://www.matrixhub.io/?q=watsonx&type=any` → "Search unavailable —
> The search service returned status 502."

A direct `curl` against `https://api.matrixhub.io/catalog/search?...`
currently returns **HTTP 500** with `{"error":"Internal Server Error",
"request_id":"..."}`. The frontend's `/api/search` proxy translates
any non-2xx into 502 with a generic message; the real upstream is the
500 we need to root-cause.

Do not touch prod again until Phase 1 is green locally.

---

## Static-review fixes already applied on this branch

A static review of the previous plan flagged four real bugs that would
have made Phase 2 fail silently or get overwritten on every deploy.
Fixed in commits on `claude/fix-matrixhub-oH85Q` before re-running
local repro:

1. **`type(exc).__name__` shadowed the route's `type` query parameter**
   in `src/routes/catalog.py`. The defensive try/except itself raised
   `TypeError: 'NoneType' object is not callable` from inside the
   handler, hiding the real exception. Fixed: use
   `exc.__class__.__name__`.

2. **`SEARCH_LEXICAL_BACKEND=pgtrgm` silently used `NullLexicalBackend`.**
   `src/services/search/__init__.py::get_lexical_backend()` does
   `from .backends.pgtrgm import PGTrgmBackend`, but
   `src/services/search/backends/pgtrgm.py` only exports a
   module-level `search()` function (no class). Import fails, factory
   falls back to the null backend, and keyword search returns empty
   results regardless of the env var.
   Fix: `src/routes/catalog.py` now ALWAYS dispatches keyword search
   via `engine.run_keyword(...)` (Option A from review). That path
   already routes to `run_pgtrgm()` when the env says `pgtrgm`, and
   to LIKE when it says `none`, with no second path through the broken
   factory.

3. **`.github/workflows/deploy.yml` overwrote `SEARCH_LEXICAL_BACKEND`
   back to `none` on every deploy**, so the proposed Phase 2
   "flip to pgtrgm on the VM" would not survive the next workflow run.
   Worse, `src/config.py` prefers `SEARCH_BACKEND__LEXICAL`
   (Pydantic AliasChoices), so setting only `SEARCH_LEXICAL_BACKEND`
   on the VM would lose to the alias anyway.
   Fix: deploy.yml now resolves the lexical backend in this order
   `workflow_dispatch input lexical_backend → vars.SEARCH_LEXICAL_BACKEND
   → default 'none'`, threads it into the SSH script, and writes
   BOTH `SEARCH_LEXICAL_BACKEND` and `SEARCH_BACKEND__LEXICAL` to that
   value.

4. **The local-repro plan was wrong.** A `--data-only` `pg_dump` does
   not bring schema with it, and Alembic+restore order matters. Phase 1
   below has the corrected ordering and a separate `--schema-only`
   flow for schema-drift detection.

---

## Plan: fix the search 502

Two phases. **Do not touch prod until Phase 1 is green locally.**

### Phase 1 — Reproduce and fix locally (no prod changes)

1. **Spin up a local Postgres** matching Aiven's major version.
   ```bash
   docker run -d --name mh-pg \
     -p 55432:5432 \
     -e POSTGRES_USER=matrix \
     -e POSTGRES_PASSWORD=matrix \
     -e POSTGRES_DB=matrixhub \
     postgres:17
   docker exec mh-pg psql -U matrix matrixhub -c \
     'CREATE EXTENSION IF NOT EXISTS pg_trgm;'
   ```

2. **Apply Alembic migrations BEFORE restoring any dump.** A data-only
   dump has rows, not table definitions — if the DB has no tables
   the restore fails immediately.
   ```bash
   DATABASE_URL='postgresql+psycopg://matrix:matrix@127.0.0.1:55432/matrixhub' \
     alembic upgrade head
   ```

3. **(Performance test) Load a slice of Aiven data.** Run on the OCI
   VM (or directly against Aiven if you have outbound 24870):
   ```bash
   pg_dump "$AIVEN_DATABASE_URL" \
     --data-only --no-owner --no-privileges \
     --table=public.entity \
     --table=public.embedding_chunk \
     --table=public.remote \
     --rows-per-insert 500 \
     | gzip > aiven-sample.sql.gz
   ```
   Then locally:
   ```bash
   gunzip -c aiven-sample.sql.gz | docker exec -i mh-pg psql -U matrix matrixhub
   docker exec mh-pg psql -U matrix matrixhub -c 'select count(*) from entity;'
   ```

4. **(Schema-drift test) Compare schemas separately** — a data-only
   dump will NOT detect missing columns. Two ways:

   a. Dump Aiven's schema and diff against the locally-migrated DB:
      ```bash
      pg_dump "$AIVEN_DATABASE_URL" \
        --schema-only --no-owner --no-privileges \
        --table=public.entity \
        --table=public.embedding_chunk \
        --table=public.remote \
        > aiven-schema.sql
      docker exec mh-pg pg_dump -U matrix --schema-only matrixhub \
        --table=public.entity --table=public.embedding_chunk --table=public.remote \
        > local-schema.sql
      diff -u local-schema.sql aiven-schema.sql
      ```

   b. Or query `information_schema.columns` directly against Aiven and
      compare the column list with what the app expects (22 columns
      including `gateway_registered_at`, `gateway_error`,
      `mcp_registration`, `manifest_blob_ref`, `tenant_id`,
      `readme_blob_ref`).

5. **Run matrix-hub locally** with prod-like env, in two
   configurations.

   First `none` (current prod behavior — LIKE fallback):
   ```bash
   SEARCH_LEXICAL_BACKEND=none \
   SEARCH_BACKEND__LEXICAL=none \
   SEARCH_DEFAULT_MODE=keyword \
   SEARCH_INCLUDE_PENDING_DEFAULT=true \
   .venv/bin/uvicorn src.app:app --host 0.0.0.0 --port 8000
   ```

   Then `pgtrgm` (target Phase 2 behavior):
   ```bash
   SEARCH_LEXICAL_BACKEND=pgtrgm \
   SEARCH_BACKEND__LEXICAL=pgtrgm \
   SEARCH_DEFAULT_MODE=keyword \
   SEARCH_INCLUDE_PENDING_DEFAULT=true \
   .venv/bin/uvicorn src.app:app --host 0.0.0.0 --port 8000
   ```

   Both should succeed because catalog.py now always goes through
   `engine.run_keyword()`, which dispatches correctly for either
   value.

6. **Reproduce with the exact frontend query.**
   ```bash
   curl -i 'http://127.0.0.1:8000/catalog/search?q=watsonx&type=any&limit=5&mode=keyword&include_pending=true'
   ```
   With the new try/except wrapper a failure returns:
   `{"detail":{"error":"SearchFailed","reason":"<ExcType>: <msg>"}}`
   instead of a bare 500.

7. **Pin the failure** to one of three suspects, ranked by likelihood
   given that the live API currently returns 500:

   a. **Schema drift on Aiven** — prod's Alembic ran against SQLite
      (`Context impl SQLiteImpl` in deploy logs), so Aiven's `entity`
      table was created by a populator script and may be missing
      columns the route SELECTs. Verify via step 4. Fix:
      `alembic upgrade head` against Aiven (one-off):
      ```bash
      docker exec matrix-hub /app/.venv/bin/alembic -c /app/alembic.ini upgrade head
      ```
      The branch's `alembic/env.py` is already patched to use
      `settings.DATABASE_URL` unconditionally.

   b. **Slow LIKE scan** timing out behind the frontend's 8 s abort.
      Less likely now that the live API returns 500 (not a 5xx from
      Cloudflare due to timeout). Verify by timing the local pgtrgm vs
      LIKE comparison. Fix: switch `SEARCH_LEXICAL_BACKEND=pgtrgm` and
      ensure the new `pg_trgm` Alembic migration
      (`9c4a1f7b3d2e_pg_trgm_extension_and_indexes.py`) ran on Aiven.

   c. **Bad row data** — a NULL where Pydantic expects a list, etc.
      Already partly mitigated (`serialize_hit()` and Pydantic
      validators coerce list columns). Verify by walking `limit`
      upwards until it crashes.

### Phase 2 — Apply the verified fix to prod

Only after Phase 1 reproduces and is fixed locally:

1. Build & publish a new image (`Publish Docker (Docker Hub)` workflow).
2. Set the repo variable `SEARCH_LEXICAL_BACKEND=pgtrgm` (Settings →
   Secrets and variables → Actions → Variables) so the deploy workflow
   pins the env on every run. Or use the `workflow_dispatch` input
   `lexical_backend=pgtrgm` for a one-shot.
3. Run `Deploy to Oracle Cloud` (workflow_dispatch).
4. Verify:
   ```bash
   curl -fsS 'https://api.matrixhub.io/catalog/search?q=watsonx&type=any&limit=5&mode=keyword&include_pending=true' | jq .
   curl -fsS 'https://www.matrixhub.io/api/search?q=watsonx&type=any&limit=5'
   ```
5. `/status` should still be green and show 7466 items.

---

## Already-pushed, awaiting next image build

These take effect once a fresh `ruslanmv/matrix-hub:latest` is published
from this branch:

- `supervisord.conf` — `[program:gateway]` pinned to `--port 4444`,
  `unset HOST PORT` before sourcing `mcpgateway/.env`.
- `Dockerfile` — `HEALTHCHECK` switched to HTTPS
  (`curl -kfsS https://127.0.0.1:443/health`), single-RUN user creation +
  `chown -R app:app /app`.
- `alembic/env.py` — unconditionally
  `config.set_main_option("sqlalchemy.url", settings.DATABASE_URL)` so
  migrations no longer fall through to SQLite.
- `alembic/versions/9c4a1f7b3d2e_pg_trgm_extension_and_indexes.py` —
  creates `pg_trgm` + 3 GIN trigram indexes on
  `entity.{name,summary,description}`. Idempotent, no-op on SQLite.
- `src/routes/catalog.py` — defensive try/except with structured
  `{detail:{error,reason}}` body, exception handler uses
  `exc.__class__.__name__` (no shadowing), keyword search ALWAYS via
  `engine.run_keyword()`.
- `.github/workflows/deploy.yml` — `SEARCH_LEXICAL_BACKEND` is
  configurable via repo variable / workflow input; both alias names
  written to .env.
- `Makefile` — `bootstrap` target, auto-installs gateway, strips CRLF,
  hub-only `dev-hub` / `run-hub` escape hatches.
- `scripts/simulate.sh` — local repro of the prod container layout.

Once the new image is live, `.github/workflows/deploy.yml` can drop
the runtime override mounts in a follow-up commit:

- `--no-healthcheck`
- `-v /home/ubuntu/supervisord.matrixhub.tls.conf:/etc/supervisor/conf.d/supervisord.conf:ro`
- `-v /home/ubuntu/start-hub-tls.sh:/app/start-hub-tls.sh:ro`
- `-v /home/ubuntu/start-gateway-4444.sh:/app/start-gateway-4444.sh:ro`

---

## Security TODOs (not blocking, but do them soon)

- **Remove private keys from the repo.** Reviewer found
  `scripts/certificates/cf-origin.key` in the tree. Even if old, treat
  it as compromised: delete it, scrub it from git history
  (`git filter-repo` or BFG), and rotate the cert.
- Rotate the **Aiven password** (`avnadmin`). The current value was
  pasted in chat at least twice today.
- Rotate the **Cloudflare Origin Cert** for `api.matrixhub.io`. Private
  key was pasted in chat earlier.
- Rotate the **GitHub PATs** that were pasted in chat.
- Set strong `JWT_SECRET_KEY` and `AUTH_ENCRYPTION_SECRET` in
  `~/matrix-hub/.env` — mcpgateway is logging weak-secret warnings.
- Set a non-default `BASIC_AUTH_PASSWORD` if `API_ALLOW_BASIC_AUTH` is
  ever enabled.
