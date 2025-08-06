#!/usr/bin/env python3
"""
Lists the most recently added 'agent', 'tool', and 'mcp_server' entities
from the Matrix Hub SQLite database, ordered by created_at DESC.

Usage:
    python3 scripts/list_top_entities.py [COUNT]

Where COUNT is the number of recent entries to show per type (default: 5).
"""

import sys
from pathlib import Path
from datetime import datetime

# Ensure project root is importable so src.config works
PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from sqlalchemy import create_engine, text
from sqlalchemy.exc import SQLAlchemyError

try:
    from src.config import settings
except ImportError:
    sys.exit("ERROR: Cannot import src.config.settings. Make sure you run from the repo root.")

# Types we care about
TYPES = ["agent", "tool", "mcp_server"]

def list_top_entities(count: int):
    engine = create_engine(settings.DATABASE_URL)
    sql = text("""
        SELECT uid, type, name, version, created_at
        FROM entity
        WHERE type = :etype
        ORDER BY created_at DESC
        LIMIT :limit
    """)
    with engine.connect() as conn:
        for etype in TYPES:
            print(f"\n=== Most recent {count} '{etype}' entities ===")
            try:
                rows = conn.execute(sql, {"etype": etype, "limit": count}).fetchall()
            except SQLAlchemyError as e:
                print(f"ERROR querying type '{etype}': {e}", file=sys.stderr)
                continue

            if not rows:
                print(f"No '{etype}' entities found.")
                continue

            # Print a header
            print(f"{'UID':<40}  {'Name':<25}  {'Version':<10}  {'Created At'}")
            print("-" * 90)
            for uid, _, name, version, created_at in rows:
                # created_at may come back as string; try to parse
                if isinstance(created_at, datetime):
                    ts = created_at.isoformat(sep=" ", timespec="seconds")
                else:
                    ts = str(created_at)
                print(f"{uid:<40}  {name:<25}  {version:<10}  {ts}")
        print()

if __name__ == "__main__":
    count = int(sys.argv[1]) if len(sys.argv) > 1 else 5
    list_top_entities(count)
