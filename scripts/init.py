#!/usr/bin/env python3
"""
Matrix-Hub catalog initializer (fully compatible with Matrix-Hub).

What this tool does
-------------------
1) Creates/maintains an ingestable matrix/index.json in one of the three shapes
   that Matrix-Hub supports natively:
   A) {"manifests": ["https://.../a.yaml", ...]}
   B) {"items": [{"manifest_url":"https://.../a.yaml"}, ...]}
   C) {"entries": [{"path":"a.yaml","base_url":"https://host/matrix/"}]}

2) Adds entries to the index:
   - add-url    : A single remote manifest URL (Form B preferred; falls back to A).
   - add-entry  : (path, base_url) pair (Form C).
   - add-inline : Copy a local manifest into ./matrix/ and add a Form-C entry.

3) Scaffolds valid manifest files (JSON) for Matrix-Hub validation:
   - scaffold-server : Generates a minimal mcp_server manifest (with mcp_registration).
   - scaffold-tool   : Generates a minimal tool manifest (type 'tool').
   - scaffold-agent  : Generates a minimal agent manifest (type 'agent') linking server/tools.

All output is placed under ./matrix by default and added to the index.

Typical workflows
-----------------
# A) Point at already-hosted manifests (Form B)
  ./scripts/init.py init-empty --shape items
  ./scripts/init.py add-url --manifest-url https://your.host/hello.manifest.json
  # Publish matrix/index.json somewhere public and set CATALOG_REMOTES=["https://your.host/matrix/index.json"]

# B) Serve local manifests (Form C)
  ./scripts/init.py init-empty --shape entries
  ./scripts/init.py scaffold-server --id hello-sse-server --name "Hello World MCP (SSE)" \
      --version 0.1.0 --transport sse --url http://127.0.0.1:8000/messages/ \
      --summary "Minimal SSE server exposing one 'hello' tool."
  ./scripts/init.py scaffold-tool --id hello-tool --name hello --version 0.1.0 \
      --summary "Return a simple greeting." \
      --input-json '{"type":"object","properties":{"name":{"type":"string"}},"required":["name"],"additionalProperties":false}'
  ./scripts/init.py scaffold-agent --id hello-agent --name "Hello Agent" --version 0.1.0 \
      --server-id hello-sse-server --tool-ids hello-tool
  # Serve repo root so Hub can fetch:  python3 -m http.server 8001
  # In Hub .env: CATALOG_REMOTES=["http://127.0.0.1:8001/matrix/index.json"]

Notes
-----
- Matrix-Hub validates manifests against its internal JSON Schemas; the scaffolds here
  include the minimal required fields: type, id, version, name, and optional metadata.
- You can use --out to select a different index file (defaults to matrix/index.json).
"""

from __future__ import annotations

import argparse
import json
import shutil
from dataclasses import dataclass, asdict
from datetime import datetime, timezone
from pathlib import Path
import sys
from typing import Dict, Any, List, Optional

DEFAULT_INDEX_PATH = Path("matrix/index.json")
VALID_SHAPES = ("manifests", "items", "entries")


# -------------------- IO helpers --------------------

def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def load_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def write_json(path: Path, obj: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2, ensure_ascii=False)
        f.write("\n")


# -------------------- Index scaffolding --------------------

def ensure_index(path: Path, shape: Optional[str] = None) -> dict:
    """
    Create minimal index if missing; else load existing.
    If creating new and 'shape' is omitted, default to 'items' (Form B).
    """
    if path.exists():
        try:
            return load_json(path)
        except Exception as e:
            sys.exit(f"ERROR: Could not read {path}: {e}")

    shape = shape or "items"
    if shape not in VALID_SHAPES:
        sys.exit(f"ERROR: shape must be one of {VALID_SHAPES}, got {shape!r}")

    idx: dict = {}
    if shape == "manifests":
        idx["manifests"] = []
    elif shape == "items":
        idx["items"] = []
    else:
        idx["entries"] = []

    idx["meta"] = {
        "format": "matrix-hub-index",
        "version": 1,
        "generated_by": "scripts/init.py",
        "created_at": now_iso(),
    }
    write_json(path, idx)
    return idx


def persist_index(path: Path, idx: dict) -> None:
    idx.setdefault("meta", {})["updated_at"] = now_iso()
    write_json(path, idx)


# -------------------- Dedup helpers --------------------

def add_manifest_url(idx: dict, url: str) -> bool:
    """
    Append a manifest URL either to Form B ("items") or Form A ("manifests").
    Returns True if new, False if duplicate.
    """
    if "items" in idx:
        items = idx.setdefault("items", [])
        if not any(isinstance(it, dict) and it.get("manifest_url") == url for it in items):
            items.append({"manifest_url": url})
            return True
        return False
    if "manifests" in idx:
        mans = idx.setdefault("manifests", [])
        if url not in mans:
            mans.append(url)
            return True
        return False
    # No supported key found; default to items
    idx["items"] = [{"manifest_url": url}]
    return True


def add_entry(idx: dict, path: str, base_url: str) -> bool:
    """
    Append a Form C entry: {"path": path, "base_url": base_url}.
    Returns True if new, False if duplicate.
    """
    entries = idx.setdefault("entries", [])
    dupe = any(
        isinstance(e, dict) and e.get("path") == path and e.get("base_url") == base_url
        for e in entries
    )
    if dupe:
        return False
    entries.append({"path": path, "base_url": base_url})
    return True


# -------------------- Manifest scaffolds --------------------

@dataclass
class BaseManifest:
    type: str
    id: str
    version: str
    name: str
    summary: Optional[str] = None
    description: Optional[str] = None
    license: Optional[str] = None
    homepage: Optional[str] = None
    publisher: Optional[str] = None


def write_manifest(dest_dir: Path, filename: str, data: Dict[str, Any]) -> Path:
    dest_dir.mkdir(parents=True, exist_ok=True)
    path = dest_dir / filename
    write_json(path, data)
    return path


def scaffold_mcp_server(
    dest_dir: Path,
    *,
    id: str,
    name: str,
    version: str,
    transport: str,
    url: str,
    summary: Optional[str] = None,
    description: Optional[str] = None,
    license: Optional[str] = None,
    homepage: Optional[str] = None,
    publisher: Optional[str] = None,
) -> Path:
    """
    Create a minimal 'mcp_server' manifest with a best-effort mcp_registration.
    """
    base = BaseManifest(
        type="mcp_server",
        id=id,
        version=version,
        name=name,
        summary=summary,
        description=description,
        license=license,
        homepage=homepage,
        publisher=publisher,
    )
    manifest: Dict[str, Any] = asdict(base)
    # Normalize transport for GW: "SSE" | "REST" | "MCP"
    transport_up = transport.strip().upper()
    manifest["mcp_registration"] = {
        "server": {
            "name": id,
            "description": summary or (description or f"{name} server"),
            "transport": transport_up,
            # For SSE: this should be the *single* SSE endpoint your server exposes
            # (one URL handling GET (server->client) and POST (client->server) is fine).
            "url": url,
        }
    }
    filename = f"{id}.manifest.json"
    return write_manifest(dest_dir, filename, manifest)


def scaffold_tool(
    dest_dir: Path,
    *,
    id: str,
    name: str,
    version: str,
    summary: Optional[str] = None,
    description: Optional[str] = None,
    input_schema_json: Optional[str] = None,
    output_schema_json: Optional[str] = None,
    license: Optional[str] = None,
    homepage: Optional[str] = None,
    publisher: Optional[str] = None,
) -> Path:
    """
    Create a minimal 'tool' manifest (Matrix-Hub requires type, id, version, name).
    """
    base = BaseManifest(
        type="tool",
        id=id,
        version=version,
        name=name,
        summary=summary,
        description=description,
        license=license,
        homepage=homepage,
        publisher=publisher,
    )
    manifest: Dict[str, Any] = asdict(base)
    # Optional schemas
    def _parse(json_text: Optional[str]) -> Any:
        if not json_text:
            return None
        try:
            return json.loads(json_text)
        except Exception as e:
            sys.exit(f"ERROR: invalid JSON for schema: {e}")

    input_schema = _parse(input_schema_json)
    output_schema = _parse(output_schema_json)
    if input_schema is not None:
        manifest["input_schema"] = input_schema
    if output_schema is not None:
        manifest["output_schema"] = output_schema
    filename = f"{id}.manifest.json"
    return write_manifest(dest_dir, filename, manifest)


def scaffold_agent(
    dest_dir: Path,
    *,
    id: str,
    name: str,
    version: str,
    server_id: str,
    tool_ids: List[str],
    summary: Optional[str] = None,
    description: Optional[str] = None,
    license: Optional[str] = None,
    homepage: Optional[str] = None,
    publisher: Optional[str] = None,
) -> Path:
    """
    Create a minimal 'agent' manifest that references a server and a list of tool ids.
    Exact schema can evolve; this sticks to conservative, self-descriptive fields.
    """
    base = BaseManifest(
        type="agent",
        id=id,
        version=version,
        name=name,
        summary=summary,
        description=description,
        license=license,
        homepage=homepage,
        publisher=publisher,
    )
    manifest: Dict[str, Any] = asdict(base)
    manifest["server"] = {"id": server_id}
    manifest["tools"] = [{"id": tid} for tid in tool_ids]
    filename = f"{id}.manifest.json"
    return write_manifest(dest_dir, filename, manifest)


# -------------------- Commands --------------------

def cmd_init_empty(a: argparse.Namespace) -> None:
    idx = ensure_index(a.out, shape=a.shape)
    persist_index(a.out, idx)
    print(f"✅ Initialized empty index at {a.out} with shape={a.shape or 'items'}")


def cmd_add_url(a: argparse.Namespace) -> None:
    idx = ensure_index(a.out)
    changed = add_manifest_url(idx, a.manifest_url)
    persist_index(a.out, idx)
    print(("✅ Added URL → " if changed else "ℹ️  URL already present → ") + a.manifest_url)


def cmd_add_entry(a: argparse.Namespace) -> None:
    idx = ensure_index(a.out, shape="entries")
    changed = add_entry(idx, a.path, a.base_url)
    persist_index(a.out, idx)
    msg = f"path={a.path}, base_url={a.base_url}"
    print(("✅ Added entry → " if changed else "ℹ️  Entry already present → ") + msg)


def cmd_add_inline(a: argparse.Namespace) -> None:
    """
    Copy local manifest into ./matrix next to index.json and add a Form-C entry.
    """
    out_index = a.out
    idx_dir = out_index.parent
    idx = ensure_index(out_index, shape="entries")

    src = Path(a.manifest).expanduser().resolve()
    if not src.exists():
        sys.exit(f"ERROR: manifest not found: {src}")

    # Use given filename or derive from source
    dest_name = a.filename or src.name
    dest = idx_dir / dest_name
    if dest.exists() and not a.force:
        # If same content, it's fine; else stop
        if dest.read_text(encoding="utf-8") != src.read_text(encoding="utf-8"):
            sys.exit(f"ERROR: {dest} already exists and differs; use --force to overwrite or choose --filename.")
    else:
        shutil.copyfile(src, dest)

    changed = add_entry(idx, path=dest.name, base_url=a.base_url)
    persist_index(out_index, idx)
    msg = f"path={dest.name}, base_url={a.base_url}"
    print(("✅ Copied and added entry → " if changed else "ℹ️  Entry already present → ") + msg)


def cmd_scaffold_server(a: argparse.Namespace) -> None:
    idx = ensure_index(a.out, shape="entries")
    idx_dir = a.out.parent
    path = scaffold_mcp_server(
        idx_dir,
        id=a.id,
        name=a.name,
        version=a.version,
        transport=a.transport,
        url=a.url,
        summary=a.summary,
        description=a.description,
        license=a.license,
        homepage=a.homepage,
        publisher=a.publisher,
    )
    changed = add_entry(idx, path=path.name, base_url=a.base_url)
    persist_index(a.out, idx)
    print(f"✅ Wrote {path} and {'added' if changed else 'found existing'} entries record (base_url={a.base_url})")


def cmd_scaffold_tool(a: argparse.Namespace) -> None:
    idx = ensure_index(a.out, shape="entries")
    idx_dir = a.out.parent
    path = scaffold_tool(
        idx_dir,
        id=a.id,
        name=a.name,
        version=a.version,
        summary=a.summary,
        description=a.description,
        input_schema_json=a.input_json,
        output_schema_json=a.output_json,
        license=a.license,
        homepage=a.homepage,
        publisher=a.publisher,
    )
    changed = add_entry(idx, path=path.name, base_url=a.base_url)
    persist_index(a.out, idx)
    print(f"✅ Wrote {path} and {'added' if changed else 'found existing'} entries record (base_url={a.base_url})")


def cmd_scaffold_agent(a: argparse.Namespace) -> None:
    idx = ensure_index(a.out, shape="entries")
    idx_dir = a.out.parent
    tool_ids = [s.strip() for s in a.tool_ids.split(",") if s.strip()]
    path = scaffold_agent(
        idx_dir,
        id=a.id,
        name=a.name,
        version=a.version,
        server_id=a.server_id,
        tool_ids=tool_ids,
        summary=a.summary,
        description=a.description,
        license=a.license,
        homepage=a.homepage,
        publisher=a.publisher,
    )
    changed = add_entry(idx, path=path.name, base_url=a.base_url)
    persist_index(a.out, idx)
    print(f"✅ Wrote {path} and {'added' if changed else 'found existing'} entries record (base_url={a.base_url})")


# -------------------- CLI --------------------

def main() -> None:
    ap = argparse.ArgumentParser(description="Init and maintain matrix/index.json (Matrix-Hub compatible)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    # init-empty
    p0 = sub.add_parser("init-empty", help="Create an empty index in a supported shape.")
    p0.add_argument("--out", type=Path, default=DEFAULT_INDEX_PATH, help="Output path (default: matrix/index.json)")
    p0.add_argument("--shape", choices=VALID_SHAPES, default="items",
                    help="Index shape: manifests | items | entries (default: items)")
    p0.set_defaults(func=cmd_init_empty)

    # add-url (Form B or A)
    p1 = sub.add_parser("add-url", help="Append one manifest URL (Form B 'items' or Form A 'manifests').")
    p1.add_argument("--out", type=Path, default=DEFAULT_INDEX_PATH)
    p1.add_argument("--manifest-url", required=True)
    p1.set_defaults(func=cmd_add_url)

    # add-entry (Form C)
    p2 = sub.add_parser("add-entry", help="Append one (path, base_url) pair (Form C 'entries').")
    p2.add_argument("--out", type=Path, default=DEFAULT_INDEX_PATH)
    p2.add_argument("--path", required=True, help="Relative path to manifest file stored alongside index.json")
    p2.add_argument("--base-url", required=True, help="Absolute base URL that serves the index folder")
    p2.set_defaults(func=cmd_add_entry)

    # add-inline (copy + add-entry)
    p3 = sub.add_parser("add-inline", help="Copy local manifest into ./matrix and add as an 'entries' record.")
    p3.add_argument("--out", type=Path, default=DEFAULT_INDEX_PATH)
    p3.add_argument("--manifest", required=True, help="Local path to YAML/JSON manifest to copy")
    p3.add_argument("--base-url", required=True, help="Absolute base URL where the index folder is served")
    p3.add_argument("--filename", default=None, help="Destination filename (defaults to source filename)")
    p3.add_argument("--force", action="store_true", help="Overwrite destination if it exists")
    p3.set_defaults(func=cmd_add_inline)

    # scaffold-server (mcp_server)
    p4 = sub.add_parser("scaffold-server", help="Create a minimal 'mcp_server' manifest and add it to the index.")
    p4.add_argument("--out", type=Path, default=DEFAULT_INDEX_PATH)
    p4.add_argument("--base-url", required=True, help="Absolute base URL where the ./matrix folder is served")
    p4.add_argument("--id", required=True)
    p4.add_argument("--name", required=True)
    p4.add_argument("--version", required=True)
    p4.add_argument("--transport", required=True, help="SSE | REST | MCP (case-insensitive)")
    p4.add_argument("--url", required=True, help="Transport URL (e.g., http://127.0.0.1:8000/messages/ for SSE)")
    p4.add_argument("--summary", default=None)
    p4.add_argument("--description", default=None)
    p4.add_argument("--license", default=None)
    p4.add_argument("--homepage", default=None)
    p4.add_argument("--publisher", default=None)
    p4.set_defaults(func=cmd_scaffold_server)

    # scaffold-tool (tool)
    p5 = sub.add_parser("scaffold-tool", help="Create a minimal 'tool' manifest and add it to the index.")
    p5.add_argument("--out", type=Path, default=DEFAULT_INDEX_PATH)
    p5.add_argument("--base-url", required=True)
    p5.add_argument("--id", required=True)
    p5.add_argument("--name", required=True)
    p5.add_argument("--version", required=True)
    p5.add_argument("--summary", default=None)
    p5.add_argument("--description", default=None)
    p5.add_argument("--input-json", default=None, help="JSON for input_schema")
    p5.add_argument("--output-json", default=None, help="JSON for output_schema")
    p5.add_argument("--license", default=None)
    p5.add_argument("--homepage", default=None)
    p5.add_argument("--publisher", default=None)
    p5.set_defaults(func=cmd_scaffold_tool)

    # scaffold-agent (agent)
    p6 = sub.add_parser("scaffold-agent", help="Create a minimal 'agent' manifest that references a server/tools.")
    p6.add_argument("--out", type=Path, default=DEFAULT_INDEX_PATH)
    p6.add_argument("--base-url", required=True)
    p6.add_argument("--id", required=True)
    p6.add_argument("--name", required=True)
    p6.add_argument("--version", required=True)
    p6.add_argument("--server-id", required=True, help="Server id that this agent uses")
    p6.add_argument("--tool-ids", required=True, help="Comma-separated tool ids")
    p6.add_argument("--summary", default=None)
    p6.add_argument("--description", default=None)
    p6.add_argument("--license", default=None)
    p6.add_argument("--homepage", default=None)
    p6.add_argument("--publisher", default=None)
    p6.set_defaults(func=cmd_scaffold_agent)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
