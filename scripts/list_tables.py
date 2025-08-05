#!/usr/bin/env python3
"""
Lists all tables present in the Matrix Hub database.

- Uses the DATABASE_URL from your src/config.py.
- Prints each table name (and columns).
- Can be run from anywhere in the repo.
"""

import sys
from pathlib import Path

# --- Ensure project root (where src/ lives) is on sys.path ---
PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from sqlalchemy import create_engine, inspect

try:
    from src.config import settings
except ImportError:
    sys.exit("ERROR: Cannot import src.config.settings. Run from repo root or check src/config.py exists.")

engine = create_engine(settings.DATABASE_URL)
inspector = inspect(engine)

print("\nTables in your Matrix Hub database:\n")

for table_name in inspector.get_table_names():
    print(f"• {table_name}")
    columns = inspector.get_columns(table_name)
    colnames = ", ".join([c['name'] for c in columns])
    print(f"    Columns: {colnames}")

print("\nDone.")
