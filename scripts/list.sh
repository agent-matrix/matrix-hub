#!/usr/bin/env bash
set -euo pipefail

# Make sure Python sees your project:
export PYTHONPATH="$(pwd)"

echo "▶ Initializing database (and applying migrations if needed)…"
python3 - <<'PY'
import sys
from alembic.config import Config
from alembic import command
from src.db import init_db

try:
    init_db()
except Exception as e:
    print(f"✖ ERROR: Failed to initialize database: {e}", file=sys.stderr)
    sys.exit(1)

# Run Alembic migrations (upgrade to head)
cfg = Config("alembic.ini")
try:
    command.upgrade(cfg, "head")
except Exception as e:
    print(f"✖ ERROR: Failed to apply migrations: {e}", file=sys.stderr)
    sys.exit(1)
PY

echo "🔎 Listing agents and mcp_servers…"
python3 - <<'PY'
import sys
from sqlalchemy.exc import OperationalError, UnboundExecutionError
import src.db as _db
from src.models import Entity

# Re-initialize (so SessionLocal gets bound to the engine built by init_db)
try:
    _db.init_db()
except Exception as e:
    print(f"✖ ERROR: Database not initialized: {e}", file=sys.stderr)
    sys.exit(1)

SessionLocal = _db.SessionLocal
session = SessionLocal()

try:
    try:
        # Query for type in ('agent','mcp_server')
        items = (
            session
            .query(Entity)
            .filter(Entity.type.in_(["agent", "mcp_server"]))
            .order_by(Entity.type, Entity.created_at.desc())
            .all()
        )
    except OperationalError as oe:
        print("✖ ERROR: Required tables not found. Have you run migrations?", file=sys.stderr)
        sys.exit(1)
    except UnboundExecutionError:
        print("✖ ERROR: Session is not bound to the engine; DB not initialized correctly.", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"✖ ERROR querying entities: {e}", file=sys.stderr)
        sys.exit(1)

    if not items:
        echo = print
        echo("  (No agents or mcp_servers found)")
        sys.exit(0)
    # Pretty‐print header
    print(f"{'Type':<12} {'UID':<36} {'Name':<30} {'Version':<8} {'Created'}")
    for e in items:
        print(f"{e.type:<12} {e.uid:<36} {e.name or '':<30} {e.version:<8} {e.created_at}")
finally:
    session.close()
PY
