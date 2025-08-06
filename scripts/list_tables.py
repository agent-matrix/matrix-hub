#!/usr/bin/env python3
"""
Lists all tables present in the Matrix Hub database,
their columns, and how many rows each contains.

- Uses the DATABASE_URL from your src/config.py.
- Prints each table name, columns, and row count.
- Can be run from anywhere in the repo.
"""

import sys
from pathlib import Path

# --- Ensure project root (where src/ lives) is on sys.path ---
PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from sqlalchemy import create_engine, inspect, text
from sqlalchemy.exc import SQLAlchemyError

try:
    from src.config import settings
except ImportError:
    sys.exit(
        "ERROR: Cannot import src.config.settings. "
        "Run from repo root or check src/config.py exists."
    )

engine = create_engine(settings.DATABASE_URL)
inspector = inspect(engine)

print("\nTables in your Matrix Hub database:\n")

with engine.connect() as conn:
    for table_name in inspector.get_table_names():
        # Columns
        columns = inspector.get_columns(table_name)
        colnames = ", ".join([c["name"] for c in columns])

        # Row count
        try:
            result = conn.execute(text(f"SELECT COUNT(*) FROM {table_name}"))
            row_count = result.scalar_one()
        except SQLAlchemyError as e:
            row_count = f"ERROR: {e}"

        # Output
        print(f"• {table_name} (rows: {row_count})")
        print(f"    Columns: {colnames}")
    print("\nDone.")
