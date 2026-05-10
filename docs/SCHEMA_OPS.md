# Schema Operations Runbook

How to keep production safe from the class of failure that produced the
`/catalog/search` 502 on 2026-05-10:

> `ProgrammingError: column entity.manifest_blob_ref does not exist`

It happened because `alembic_version` was stamped to head but the
matching migration's DDL had never actually run on Aiven. Industry
practice: never silently mutate `alembic_version`; always reconcile
schema first.

## Defenses now in place

| Layer | What it catches |
|---|---|
| `alembic/versions/4b8f2c5d9e1a_*.py` | All DDL is `IF NOT EXISTS` / introspection-guarded — re-runs are safe under retries, partial deploys, rollbacks. |
| `scripts/_alembic_heal.py` | Refuses to stamp head on Postgres when version_num is unknown; defers to `repair_db.py`. Returns rc=2 on refusal. |
| `scripts/repair_db.py` (`make repair-db`) | Operator-facing, idempotent reconciliation: ADD COLUMN IF NOT EXISTS for missing ORM columns, CREATE TABLE/INDEX/EXTENSION IF NOT EXISTS, then stamp head. Single transaction. |
| `scripts/check_schema_drift.py` | Boot-time gate. Compares live DB against the ORM's required-columns set; refuses to start the Hub on drift. |
| `run_prod.sh` / `run_dev.sh` | Honor heal rc=2 and drift rc=2 → fatal error, abort startup with a "Run `make repair-db`" message. |
| `.github/workflows/migrations-ci.yml` | Per-PR: round-trip `up → down → up` against fresh Postgres 17, drift check, regression suite. |
| `tests/test_search_regressions.py::test_required_orm_columns_match_required_set` | Forces same-PR update of the drift checker when an ORM column is added. |

## When the prod search returns 5xx

1. **Reproduce locally** with a clone of `.env` (Aiven URL):

   ```bash
   make stop && make run
   curl -sS 'http://localhost:8000/catalog/search?q=slack&type=any&mode=keyword' | jq .
   ```

   If the error envelope says `column ... does not exist`, you have schema drift.

2. **Preview the repair**:

   ```bash
   make repair-db DRY=1
   ```

   It prints the planned actions (ADD COLUMN, CREATE TABLE, …) without
   touching the DB. If the plan is empty, drift is elsewhere — escalate.

3. **Apply the repair** (idempotent, atomic):

   ```bash
   make repair-db
   ```

4. **Verify**:

   ```bash
   .venv/bin/python scripts/check_schema_drift.py
   curl -sS 'http://localhost:8000/catalog/search?q=slack&type=any&mode=keyword' | jq '.total'
   ```

5. **Restart** the Hub container in production. (The schema fix is in
   the shared Aiven DB, so the running container just needs a fresh
   connection pool. No image rebuild required to clear the 5xx.)

## When you add a new column to the ORM

1. Add it to `src/models.py::Entity`.
2. Add it to `scripts/check_schema_drift.py::REQUIRED_ENTITY_COLUMNS`.
   (`tests/test_search_regressions.py::test_required_orm_columns_match_required_set`
   will fail otherwise — that's the gate.)
3. Add it to `scripts/repair_db.py::ENTITY_COLUMNS_DDL` (with the right
   Postgres type) so the operator-facing repair can heal a future drift.
4. Write the migration with **idempotent DDL**:

   ```python
   def upgrade():
       if op.get_bind().dialect.name == "postgresql":
           op.execute("ALTER TABLE entity ADD COLUMN IF NOT EXISTS new_col VARCHAR")
       else:
           # SQLite branch (dev only)
           insp = sa.inspect(op.get_bind())
           if "new_col" not in {c["name"] for c in insp.get_columns("entity")}:
               op.add_column("entity", sa.Column("new_col", sa.String(), nullable=True))
   ```

5. The migrations CI workflow will validate `up → down → up` round-trip
   against fresh Postgres 17 before the PR is allowed to merge.

## When `alembic_version` gets stuck on a deleted revision

Symptom in heal logs:

```
[alembic-heal] bogus version on Postgres (alembic_version='xxxxxxxxxxxx' not found in migrations dir)
```

This means a previously deployed branch ran a migration whose file has
since been removed from `alembic/versions/`. Recovery:

1. Run `make repair-db` — it stamps head and adds any missing schema bits.
2. Open a PR that adds a CI gate to `.github/workflows/ci.yml` to
   validate every revision in `alembic_version` of the deployed
   environment exists in the merge target's `versions/`. (Future TODO.)

## Database role separation (target state)

Today everything uses `avnadmin`. Industry practice splits:

| Role | Permissions | Used by |
|---|---|---|
| `matrixhub_app` | CRUD on `public.*` | Runtime (gunicorn workers) |
| `matrixhub_migrator` | DDL + CRUD | `alembic upgrade head` step in CI/deploy |
| `matrixhub_readonly` | SELECT only | Diagnostics (`mh_check.sh`, support staff) |

Create them once, then use the right role in each context. `avnadmin`
should be reserved for emergency break-glass.

## Aiven IP allowlist (target state)

Currently "Open to all" — anyone on the public internet can attempt
auth against the Postgres port. Restrict to:

- The Oracle Cloud VM running the prod container.
- The GitHub Actions runner CIDR if `deploy.yml` runs SQL directly.
- Time-boxed operator IPs during incidents.

## Connection pool sizing

Aiven free tier has a hard **20-connection limit**. Recommend:

```env
DB_POOL_SIZE=2
DB_MAX_OVERFLOW=2
DB_POOL_TIMEOUT=5
DB_POOL_RECYCLE=1800
```

With a single gunicorn worker that's 4 active + 4 hot-spare connections,
leaving 12 for migrations, diagnostics, and the gateway.
