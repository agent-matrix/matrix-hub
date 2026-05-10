# TODO — next session

> Last updated 2026-05-10 after PR #22 merged everything below the
> `~~strikethrough~~` items into `master`.

## Status snapshot (2026-05-10)

`https://www.matrixhub.io/status` is fully green:

| Row       | State                                  |
| --------- | -------------------------------------- |
| API       | **Operational** (`api.matrixhub.io`)   |
| Database  | **Connected** (Aiven Postgres 17)      |
| Frontend  | **Operational** (Next.js on Vercel)    |
| Catalog   | **7466 items** indexed                 |

The only red signal:

> `https://www.matrixhub.io/?q=watsonx&type=any` →
> "Search unavailable — The search service returned status 502."

The frontend `/api/search` proxy returns 502 whenever the backend
`/catalog/search` returns any non-2xx OR times out at 8 s. Until the
new Docker image is published from `master`, the running container
returns a bare `{"error":"Internal Server Error","request_id":"..."}` —
the structured `{detail:{error,reason}}` envelope from this branch
isn't live yet.

---

## ✅ Resolved since last update (now on `master`)

### Search-route correctness
- Defensive `try/except` around `/catalog/search` returns
  `{detail:{error:"SearchFailed",reason:"<class>: <msg>"}}` instead of
  bare 500.
- Exception handler uses `exc.__class__.__name__` (was `type(exc)`,
  which the `type=` query param shadowed → `TypeError: 'NoneType' is
  not callable` from inside the handler).
- Keyword search **always** dispatches via `engine.run_keyword()`. The
  legacy `lexical.search()` singleton silently fell through to
  `NullLexicalBackend` because `services/search/__init__.py` imports
  a non-existent `PGTrgmBackend` class (the backend module exports
  only a module-level `search()` function).

### Container image (`Dockerfile`)
- HTTPS healthcheck (`curl -kfsS https://127.0.0.1:443/health`) —
  was HTTP, guaranteed-fail against gunicorn-on-TLS.
- start-period 60s, retries 5 (was 40s/3) — Alembic against fresh
  Aiven needs longer.
- Single-RUN user creation + `mkdir -p /app/data/blobs` + `chown -R app:app /app`
  (was chown-before-user, `invalid user` build failure on amd64+arm64).
- `ENTRYPOINT` correctly wires `docker-entrypoint.sh` →
  `select_database_url.sh` (Aiven primary / OL9 fallback).
- New Alembic migration `9c4a1f7b3d2e_pg_trgm_extension_and_indexes.py`:
  idempotent `CREATE EXTENSION pg_trgm` + GIN trigram indexes on
  `entity.{name,summary,description}`. No-op on SQLite.
- `Dockerfile.prod` aligned with `Dockerfile` (was missing ENTRYPOINT,
  `postgresql-client`, `scripts/`, `httpx[http2]`, `psycopg[binary]`
  in gateway venv, GATEWAY_REF arg, `mkdir blobs`, SQLite scrubs).
- `supervisord.conf`: gateway pinned to `--port 4444` via CLI flag,
  `unset HOST PORT` before sourcing `mcpgateway/.env` so the gateway
  can never race the Hub for `:443`.
- `alembic/env.py` unconditionally uses `settings.DATABASE_URL` (was
  falling through to the SQLite default in `alembic.ini`, which
  caused `Context impl SQLiteImpl` in prod logs and a phantom
  parallel SQLite migration history).

### Deploy workflow (`.github/workflows/deploy.yml`)
- `SEARCH_LEXICAL_BACKEND` is now configurable, resolved in this
  order:
    1. `workflow_dispatch input lexical_backend` (one-shot override)
    2. repo variable `SEARCH_LEXICAL_BACKEND`
    3. literal default `none`.
  Both `SEARCH_LEXICAL_BACKEND` and `SEARCH_BACKEND__LEXICAL` are
  written so Pydantic `AliasChoices` precedence can't sabotage the
  config.
- `AIVEN_DATABASE_URL` accepts any of `postgres://`, `postgresql://`,
  or `postgresql+psycopg://` (auto-converts the libpq forms to the
  SQLAlchemy form expected by psycopg3).
- `--no-healthcheck` + runtime `supervisord.matrixhub.tls.conf` /
  `start-hub-tls.sh` / `start-gateway-4444.sh` mounts — defensive
  overrides that keep the deploy working until a fresh image with
  the baked-in fixes is published. **These can be removed after the
  next `Publish Docker` run completes.**
- Strict TLS check + `exit 1` on Cloudflare 525.
- `matrixhub_data` volume gets `mkdir blobs && chown 999:999 && chmod`
  before container start — fixes `PermissionError: /app/data/blobs`.

### Local dev experience (`Makefile`, `scripts/setup-mcp-gateway.sh`)
- `make install` is now the **prod-ready one-shot** (Hub venv +
  Gateway venv + `.env`). It does **not** start any service —
  `make run` is the only target that binds ports.
  `make bootstrap` is kept as an alias.
- `make stop` — TERMs Hub + Gateway processes (PID files, then
  `pgrep -x <basename>`, then force-kill anything still on
  :443/:4444/`$PORT`). Uses `pgrep -x` instead of `-f` to avoid the
  self-match landmine that previously killed the recipe mid-run.
- `make clean` depends on `make stop` so a rebuild always starts from
  a quiet state. `make clean-all` also nukes `.env`.
- `make run-hub` / `make dev-hub` — Hub-only escape hatches (skip
  Gateway entirely; useful when debugging only `/catalog` or
  `/health`).
- `make` targets that invoke shell scripts now run `fix-line-endings`
  first — strips CRLF in-place, so WSL/Windows checkouts no longer
  fail with cryptic `command not found`.
- `setup-mcp-gateway.sh` self-heals four common failure modes:
    1. missing `python3.11-venv` apt package → `apt install` and retry
    2. uv-managed Python (sys.prefix=/install) → prefer `/usr/bin/python3.11`
    3. `--without-pip` + `get-pip.py` bootstrap if ensurepip dies
    4. half-built `.venv` from a previous failed run → wipe and retry
- `setup-mcp-gateway.sh` accepts `--no-start` (used by
  `gateway-ensure` from the Makefile so install never starts services
  that `make run` would then collide with on :4444).
- `uv pip install` used everywhere uv is on PATH (10-20× faster than
  pip; sidesteps the `Cannot uninstall wheel installed by debian`
  crash that pip hits in uv-bootstrapped venvs).
- `UV_LINK_MODE=copy` exported by both Makefile and setup script —
  silences the noisy WSL hardlink-fallback warning when the project
  tree (`/mnt/c`) and uv cache (`~/.cache/uv` on Linux ext4) are on
  different filesystems.
- Verbose `[1/3] [2/3] [3/3]` progress markers during venv build —
  no more "frozen at -> Constructing reality" UX.

---

## 🔲 Open: production search-502 fix

Two phases. **Do not touch prod until Phase 1 is green locally.**

### Phase 1 — Reproduce locally (against Aiven, on WSL or any host
                                  with outbound `:24870`)

```bash
cd /mnt/c/workspace/matrix-hub   # or wherever you cloned
git pull origin master           # all the fixes above are now in master

# Confirm the WSL/host can reach Aiven
timeout 10 bash -c 'cat </dev/null >/dev/tcp/pg-37455d5-matrixhub-db.c.aivencloud.com/24870 && echo TCP_OK' \
  || echo "TCP closed — open egress to :24870 first"

# .env with Aiven URL + pgtrgm:
#   DATABASE_URL=postgresql+psycopg://avnadmin:<PW>@pg-37455d5-...aivencloud.com:24870/defaultdb?sslmode=require
#   SEARCH_LEXICAL_BACKEND=pgtrgm
#   SEARCH_BACKEND__LEXICAL=pgtrgm
#   SEARCH_DEFAULT_MODE=keyword
#   SEARCH_INCLUDE_PENDING_DEFAULT=true
#   MATRIX_ENV=development
#   REQUIRE_API_TOKEN_IN_PROD=false
#   PUBLIC_BASE_URL=http://127.0.0.1:8000
make stop
make clean
make install        # ~50-90s; idempotent
make dev-hub        # Hub-only on :8000 (no sudo needed)
```

In another terminal:

```bash
# health
curl -fsS 'http://127.0.0.1:8000/health?check_db=true'
# → {"status":"ok","db":"ok"}

# the failing prod query
curl -i 'http://127.0.0.1:8000/catalog/search?q=watsonx&type=any&limit=5&mode=keyword&include_pending=true'
```

Three possible outcomes (the new `{detail:{error,reason}}` envelope
makes them legible):

1. **HTTP 200 + items** → search works locally against Aiven; the
   prod 502 is purely image-staleness. Skip to Phase 2.

2. **HTTP 500 with `{"detail":{"error":"SearchFailed","reason":"<class>: <msg>"}}`**
   — paste the `reason`. Most likely values and one-shot fixes:

   | reason                                                | one-shot fix                                                                                  |
   |-------------------------------------------------------|-----------------------------------------------------------------------------------------------|
   | `UndefinedFunction: function similarity(...) does not exist` | `psql "$DATABASE_URL" -c 'CREATE EXTENSION IF NOT EXISTS pg_trgm;'`                          |
   | `UndefinedColumn: column entity.X does not exist`     | `DATABASE_URL='<sqlalchemy-form-aiven-url>' .venv/bin/alembic upgrade head`                   |
   | `ValidationError: ... capabilities ...`               | bad row in `entity`; we'll patch `serialize_hit` to coerce to `[]`                            |

   The new `9c4a1f7b3d2e_pg_trgm_extension_and_indexes.py` migration
   does both `CREATE EXTENSION` and the GIN indexes idempotently when
   `alembic upgrade head` runs at Hub startup. So once the new image
   is deployed AND the Hub is allowed to migrate Aiven, both #1 and #2
   become impossible.

3. **Connection timeout to Aiven** → your host doesn't have outbound
   to `:24870`. Open the firewall / use a VPN / SSH tunnel and retry.

### Phase 2 — Apply the verified fix to prod

Only after Phase 1 returns 200 locally:

1. **Build & publish a new image.** Trigger
   `📦 Publish Docker (Docker Hub)` workflow_dispatch on `master`.
2. **Set the repo variable** `SEARCH_LEXICAL_BACKEND=pgtrgm`
   (Settings → Secrets and variables → Actions → Variables) so every
   future `Deploy to Oracle Cloud` run uses the production search
   path. (Or use the `lexical_backend` workflow_dispatch input for a
   one-shot.)
3. **Run** `Deploy to Oracle Cloud` (workflow_dispatch).
4. **Verify**:
   ```bash
   curl -fsS 'https://api.matrixhub.io/catalog/search?q=watsonx&type=any&limit=5&mode=keyword&include_pending=true' | jq .
   curl -fsS 'https://www.matrixhub.io/api/search?q=watsonx&type=any&limit=5'
   ```
   `/status` should still be green and Catalog should still show 7466.
5. **Drop the runtime override mounts** from `deploy.yml` in a
   follow-up commit (the new image bakes them in):
   - `--no-healthcheck`
   - `-v /home/ubuntu/supervisord.matrixhub.tls.conf:/etc/supervisor/conf.d/supervisord.conf:ro`
   - `-v /home/ubuntu/start-hub-tls.sh:/app/start-hub-tls.sh:ro`
   - `-v /home/ubuntu/start-gateway-4444.sh:/app/start-gateway-4444.sh:ro`

---

## 🔲 Security TODOs (not blocking, but do them soon)

- **Remove private keys from the repo.** Reviewer found
  `scripts/certificates/cf-origin.key` in the tree. Even if old, treat
  it as compromised: delete it, scrub it from git history
  (`git filter-repo` or BFG), and rotate the cert.
- Rotate the **Aiven password** (`avnadmin`) — pasted in chat at least
  three times during debugging.
- Rotate the **Cloudflare Origin Cert** for `api.matrixhub.io` — the
  private key was pasted in chat earlier.
- Rotate the **GitHub PATs** pasted in chat.
- Set strong `JWT_SECRET_KEY` and `AUTH_ENCRYPTION_SECRET` in
  `~/matrix-hub/.env` — mcpgateway logs weak-secret warnings on every
  boot.
- Set a non-default `BASIC_AUTH_PASSWORD` before enabling
  `API_ALLOW_BASIC_AUTH`.

---

## 🔲 Nice-to-have follow-ups (no urgency)

- **Move project tree to Linux ext4 on WSL** (`~/matrix-hub` instead
  of `/mnt/c/workspace/matrix-hub`) — `make install` would drop from
  ~60 s to ~10-15 s on a cold cache. Filesystem-bound.
- **Delete `Dockerfile.prod`** if no operator actually uses
  `scripts/build_container_prod.sh`. The canonical `Dockerfile`
  covers prod equally well via `--build-arg HUB_INSTALL_TARGET=prod`.
  (We aligned the two files in the meantime to avoid divergence.)
- **Add a unit test** that exercises `/catalog/search` against an
  in-memory SQLite seeded with a few entities — would catch
  regressions in the search route before they reach prod.
- **Switch `Publish Docker` to also tag `:master`** in addition to
  `:latest` and the semver tag, so the deploy can pin to a specific
  master commit if needed.
