"""pg_trgm extension + GIN trigram indexes for catalog search

Revision ID: 9c4a1f7b3d2e
Revises: 4b8f2c5d9e1a
Create Date: 2026-05-09

Why this migration
------------------
The `pgtrgm` lexical search backend
(`src/services/search/backends/pgtrgm.py`) calls Postgres'
`similarity()` function and `ILIKE` over `entity.name`,
`entity.summary`, `entity.description`. Without the `pg_trgm`
extension, `similarity()` is undefined and the query fails. Without
GIN trigram indexes, `ILIKE %q%` over thousands of rows is a full
table scan and times out behind the frontend's 8s abort, surfacing as
"Search unavailable / 502".

This migration:
  1. Creates the `pg_trgm` extension on Postgres (no-op on SQLite).
  2. Adds GIN trigram indexes on the three text columns the backend
     actually queries.

All operations are guarded by `IF NOT EXISTS`, so this migration is
safe to run on any Postgres database — fresh, partially-migrated, or
already trigram-aware.

Operator action
---------------
After this migration runs against Aiven (the next deploy will trigger
it via the Alembic `upgrade head` step in src/db.py), flip the env
var so the production search backend is used:

    SEARCH_LEXICAL_BACKEND=pgtrgm

(or leave it as `none` if the operator prefers the dev fallback;
both paths work, but the pgtrgm path is much faster and ranks better.)
"""

from __future__ import annotations

from alembic import op

# revision identifiers, used by Alembic.
revision = "9c4a1f7b3d2e"
down_revision = "4b8f2c5d9e1a"
branch_labels = None
depends_on = None


def _is_postgres() -> bool:
    bind = op.get_bind()
    return (bind.dialect.name or "").lower() == "postgresql"


def upgrade() -> None:
    if not _is_postgres():
        # SQLite (dev) doesn't have pg_trgm; the LIKE fallback in
        # src/services/search/lexical_none.py covers that case.
        return

    op.execute("CREATE EXTENSION IF NOT EXISTS pg_trgm;")

    # GIN trigram indexes for ILIKE %q% lookups. We use IF NOT EXISTS
    # because operators may have created these by hand on the live DB.
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_entity_name_trgm "
        "ON entity USING gin (name gin_trgm_ops);"
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_entity_summary_trgm "
        "ON entity USING gin (summary gin_trgm_ops);"
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_entity_description_trgm "
        "ON entity USING gin (description gin_trgm_ops);"
    )


def downgrade() -> None:
    if not _is_postgres():
        return

    op.execute("DROP INDEX IF EXISTS ix_entity_description_trgm;")
    op.execute("DROP INDEX IF EXISTS ix_entity_summary_trgm;")
    op.execute("DROP INDEX IF EXISTS ix_entity_name_trgm;")
    # Deliberately do NOT drop the pg_trgm extension on downgrade —
    # other tables/indexes in the same database may depend on it.
