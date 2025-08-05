#!/usr/bin/env python3
"""
scripts/list_agents_mcp.py

List all 'agent' and 'mcp_server' entities in the Matrix Hub database,
auto-creating any missing tables so you don’t hit “no such table” errors.
"""

import sys
from pathlib import Path

# 1) Ensure the project root (parent of this scripts/ folder) is on PYTHONPATH
PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from src.db import init_db, close_db, SessionLocal, _engine
from src.models import Base, Entity

def main():
    print("▶ Initializing database…")
    init_db()

    # --- Use _engine directly to ensure we have an Engine ---
    engine = _engine
    if engine is None:
        print("✖ ERROR: Database engine is not initialized.", file=sys.stderr)
        sys.exit(2)

    print("▶ Ensuring tables exist (creating missing tables)…")
    Base.metadata.create_all(bind=engine)

    session = SessionLocal()
    try:
        # 4) Query for agent & mcp_server entities
        print("\nAgents and MCP Servers in Matrix Hub:\n")
        rows = (
            session
            .query(Entity)
            .filter(Entity.type.in_(["agent", "mcp_server"]))
            .order_by(Entity.type, Entity.created_at.desc())
            .all()
        )

        if not rows:
            print("  (none found)")
        else:
            for e in rows:
                ts = e.created_at.isoformat(sep=" ")
                name = e.name or "<no name>"
                print(f"  • {e.uid:30}  type={e.type:10}  name={name:20}  version={e.version:7}  created={ts}")
    except Exception as e:
        print(f"✖ Failed to query entities: {e}", file=sys.stderr)
        sys.exit(1)
    finally:
        session.close()
        close_db()

if __name__ == "__main__":
    main()
