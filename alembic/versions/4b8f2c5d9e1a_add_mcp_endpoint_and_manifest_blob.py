"""Add MCP endpoint table and manifest blob ref

Revision ID: 4b8f2c5d9e1a
Revises: 3df1dc689abe
Create Date: 2025-12-27 00:00:00.000000

This migration adds:
1. manifest_blob_ref column to entity table (for storing manifests in blob storage)
2. mcp_endpoint table for storing MCP connection details separately

Idempotency note
----------------
Production Postgres deployments have shown drift where this migration's
DDL was partially applied (e.g. column existed but mcp_endpoint table
didn't, or vice-versa) due to Alembic version pointers being rewritten
out-of-band. We therefore use `IF NOT EXISTS` guards via raw DDL so
re-running this migration on a partially-migrated DB is safe and
idempotent. SQLite (dev) doesn't support `ADD COLUMN IF NOT EXISTS`
in older versions; we fall back to introspection for that dialect.
"""

from __future__ import annotations

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = '4b8f2c5d9e1a'
down_revision = '3df1dc689abe'
branch_labels = None
depends_on = None


def _is_postgres() -> bool:
    bind = op.get_bind()
    return (bind.dialect.name or "").lower() == "postgresql"


def _entity_has_column(name: str) -> bool:
    bind = op.get_bind()
    insp = sa.inspect(bind)
    return name in {c["name"] for c in insp.get_columns("entity")}


def _table_exists(name: str) -> bool:
    bind = op.get_bind()
    insp = sa.inspect(bind)
    return name in set(insp.get_table_names())


def upgrade() -> None:
    # 1) Add manifest_blob_ref column to entity table.
    if _is_postgres():
        op.execute("ALTER TABLE entity ADD COLUMN IF NOT EXISTS manifest_blob_ref VARCHAR")
    elif not _entity_has_column("manifest_blob_ref"):
        op.add_column(
            "entity",
            sa.Column("manifest_blob_ref", sa.String(), nullable=True),
        )

    # 2) Create mcp_endpoint table.
    if _is_postgres():
        op.execute(
            """
            CREATE TABLE IF NOT EXISTS mcp_endpoint (
              entity_uid VARCHAR PRIMARY KEY REFERENCES entity(uid) ON DELETE CASCADE,
              transport VARCHAR NOT NULL,
              url VARCHAR,
              command VARCHAR,
              args_json JSON,
              env_json JSON,
              headers_json JSON,
              auth_json JSON,
              discovery_json JSON,
              created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
              updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
              CONSTRAINT ck_mcp_endpoint_transport
                CHECK (transport IN ('SSE','STDIO','WEBSOCKET','HTTP'))
            )
            """
        )
    elif not _table_exists("mcp_endpoint"):
        op.create_table(
            "mcp_endpoint",
            sa.Column("entity_uid", sa.String(),
                      sa.ForeignKey("entity.uid", ondelete="CASCADE"),
                      primary_key=True, nullable=False),
            sa.Column("transport", sa.String(), nullable=False),
            sa.Column("url", sa.String(), nullable=True),
            sa.Column("command", sa.String(), nullable=True),
            sa.Column("args_json", sa.JSON(), nullable=True),
            sa.Column("env_json", sa.JSON(), nullable=True),
            sa.Column("headers_json", sa.JSON(), nullable=True),
            sa.Column("auth_json", sa.JSON(), nullable=True),
            sa.Column("discovery_json", sa.JSON(), nullable=True),
            sa.Column("created_at", sa.DateTime(timezone=True), nullable=False,
                      server_default=sa.text("CURRENT_TIMESTAMP")),
            sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False,
                      server_default=sa.text("CURRENT_TIMESTAMP"),
                      onupdate=sa.text("CURRENT_TIMESTAMP")),
            sa.CheckConstraint(
                "transport in ('SSE','STDIO','WEBSOCKET','HTTP')",
                name="ck_mcp_endpoint_transport",
            ),
        )


def downgrade() -> None:
    if _is_postgres():
        op.execute("DROP TABLE IF EXISTS mcp_endpoint")
        op.execute("ALTER TABLE entity DROP COLUMN IF EXISTS manifest_blob_ref")
    else:
        if _table_exists("mcp_endpoint"):
            op.drop_table("mcp_endpoint")
        if _entity_has_column("manifest_blob_ref"):
            op.drop_column("entity", "manifest_blob_ref")
