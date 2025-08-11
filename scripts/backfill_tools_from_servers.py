#!/usr/bin/env python3
from __future__ import annotations
import sys, json
from pathlib import Path
from sqlalchemy import create_engine, text
from sqlalchemy.orm import Session

# add project root
ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from src.config import settings
from src.db import upsert_entity

def derive_tool_from_row(row: dict) -> dict | None:
    reg = row.get("mcp_registration")
    # ← NEW: parse JSON string if needed
    if isinstance(reg, str):
        try:
            reg = json.loads(reg)
        except Exception:
            reg = None
    if not isinstance(reg, dict):
        return None

    tool = reg.get("tool")
    if not tool:
        return None

    return {
        "type": "tool",
        "id": tool.get("id") or f"{row['id']}-tool",
        "name": tool.get("name") or row["name"],
        "version": row["version"],
        "summary": tool.get("description") or (row.get("summary") or ""),
        "description": tool.get("description") or "",
        "capabilities": row.get("capabilities"),
        "frameworks": row.get("frameworks"),
        "providers": row.get("providers"),
        "source_url": row.get("source_url"),
    }

engine = create_engine(settings.DATABASE_URL, future=True)
with Session(engine) as s:
    rows = s.execute(text("""
        SELECT
          uid, type, name, version, summary, description,
          capabilities, frameworks, providers, source_url, mcp_registration,
          substr(uid, instr(uid, ':')+1, instr(uid, '@')-instr(uid, ':')-1) AS id
        FROM entity
        WHERE type='mcp_server'
    """)).mappings().all()

    created = 0
    for r in rows:
        tool_manifest = derive_tool_from_row(dict(r))
        if not tool_manifest:
            continue
        upsert_entity(tool_manifest, s)   # no commit inside
        created += 1
    s.commit()
    print(f"Derived/updated tool rows: {created}")
