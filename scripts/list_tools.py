#!/usr/bin/env python3
"""
Lists derived `tool` entities from the Matrix Hub database.

- Uses src/config.py settings for DATABASE_URL
- Prints whether DERIVE_TOOLS_FROM_MCP is enabled
- Shows a total count of tools + recent N rows
"""

import os
import sys
from pathlib import Path
from datetime import datetime

# Ensure project root (where src/ lives) is on sys.path
PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from sqlalchemy import create_engine, text
from sqlalchemy.exc import SQLAlchemyError

try:
    from src.config import settings
except Exception as e:
    sys.exit(f"ERROR: Cannot import src.config.settings ({e}). Run from repo root?")

# Read limit
try:
    LIMIT = int(os.environ.get("LIMIT", "10"))
except ValueError:
    LIMIT = 10

db_url = os.environ.get("DATABASE_URL", settings.DATABASE_URL)

print("─" * 70)
print(" Tool entity inspection ".center(70, "─"))
print("─" * 70)
print(f" DATABASE_URL           : {db_url}")
derive_flag = getattr(settings, "DERIVE_TOOLS_FROM_MCP", False)
print(f" DERIVE_TOOLS_FROM_MCP  : {derive_flag}")
print(f" LIMIT                  : {LIMIT}")
print("─" * 70)

engine = create_engine(db_url, future=True)

with engine.connect() as conn:
    # Check the entity table exists
    try:
        conn.execute(text("SELECT 1 FROM entity LIMIT 1"))
    except SQLAlchemyError as e:
        sys.exit(f"ERROR: Could not read from 'entity' table: {e}")

    # Count tool rows
    total_tools = 0
    try:
        total_tools = conn.execute(
            text("SELECT COUNT(*) FROM entity WHERE type = 'tool'")
        ).scalar_one()
    except SQLAlchemyError as e:
        sys.exit(f"ERROR: Count query failed: {e}")

    print(f"\nTotal 'tool' entities: {total_tools}\n")

    if total_tools == 0:
        print("No 'tool' rows found.")
        print("\nHints:")
        print(" • Ensure DERIVE_TOOLS_FROM_MCP=true when running /catalog/install")
        print(" • The manifest must include mcp_registration.tool {...}")
        print(" • After enabling the flag, re-run your install for the server manifest")
        sys.exit(0)

    # Show recent tools
    try:
        rows = conn.execute(
            text(
                """
                SELECT uid, name, version, COALESCE(summary, '') AS summary, created_at
                FROM entity
                WHERE type = 'tool'
                ORDER BY created_at DESC
                LIMIT :limit
                """
            ),
            {"limit": LIMIT},
        ).mappings().all()
    except SQLAlchemyError as e:
        sys.exit(f"ERROR: Select tools failed: {e}")

    print("Recent tools:\n")
    print(f"{'UID':<40}  {'Name':<24}  {'Version':<10}  {'Created At':<20}")
    print("-" * 100)
    for r in rows:
        uid = (r["uid"] or "")[:40]
        name = (r["name"] or "")[:24]
        ver = (r["version"] or "")[:10]
        created = r["created_at"]
        if isinstance(created, (int, float)):
            created = datetime.fromtimestamp(created)
        created_s = str(created)[:19] if created else ""
        print(f"{uid:<40}  {name:<24}  {ver:<10}  {created_s:<20}")

    # Optional: show a short summary snippet for the newest tool
    newest = rows[0]
    if newest and newest.get("summary"):
        print("\nNewest tool summary (first 200 chars):")
        print((newest["summary"] or "")[:200])

print("\nDone.")
