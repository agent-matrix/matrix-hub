"""Add MCP endpoint table and manifest blob ref

Revision ID: 4b8f2c5d9e1a
Revises: 3df1dc689abe
Create Date: 2025-12-27 00:00:00.000000

This migration adds:
1. manifest_blob_ref column to entity table (for storing manifests in blob storage)
2. mcp_endpoint table for storing MCP connection details separately
"""

from __future__ import annotations

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = '4b8f2c5d9e1a'
down_revision = '3df1dc689abe'
branch_labels = None
depends_on = None


def upgrade() -> None:
    # 1) Add manifest_blob_ref column to entity table
    op.add_column(
        'entity',
        sa.Column('manifest_blob_ref', sa.String(), nullable=True)
    )

    # 2) Create mcp_endpoint table
    op.create_table(
        'mcp_endpoint',
        sa.Column('entity_uid', sa.String(),
                  sa.ForeignKey('entity.uid', ondelete='CASCADE'),
                  primary_key=True, nullable=False),
        sa.Column('transport', sa.String(), nullable=False),
        sa.Column('url', sa.String(), nullable=True),
        # STDIO support (future)
        sa.Column('command', sa.String(), nullable=True),
        sa.Column('args_json', sa.JSON(), nullable=True),
        sa.Column('env_json', sa.JSON(), nullable=True),
        # HTTP headers and auth
        sa.Column('headers_json', sa.JSON(), nullable=True),
        sa.Column('auth_json', sa.JSON(), nullable=True),
        # Discovery metadata
        sa.Column('discovery_json', sa.JSON(), nullable=True),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False,
                  server_default=sa.text("CURRENT_TIMESTAMP")),
        sa.Column('updated_at', sa.DateTime(timezone=True), nullable=False,
                  server_default=sa.text("CURRENT_TIMESTAMP"),
                  onupdate=sa.text("CURRENT_TIMESTAMP")),
        # Transport type constraint
        sa.CheckConstraint(
            "transport in ('SSE','STDIO','WEBSOCKET','HTTP')",
            name="ck_mcp_endpoint_transport"
        ),
    )


def downgrade() -> None:
    # Drop mcp_endpoint table
    op.drop_table('mcp_endpoint')

    # Drop manifest_blob_ref column from entity
    op.drop_column('entity', 'manifest_blob_ref')
