# src/utils/tools.py
"""
Utilities for installation operations that do not belong in the main installer
service. This module currently provides:
  - install_inline_manifest: perform a complete install from an inline manifest.

Why this module?
- Keeps src/services/install.py smaller and focused on DB-backed installs.
- Allows calling an inline-install flow directly from routes without requiring
  a prior ingest or DB Entity → source_url setup.

The inline install reuses helpers from install.py to ensure consistent behavior:
  - artifact installation (pypi/oci/git/zip)
  - adapters writing
  - MCP-Gateway registration
  - lockfile writing
  - (NEW) optional catalog save to DB for inline installs
"""

from __future__ import annotations

import logging
from dataclasses import asdict
from pathlib import Path
from typing import Any, Dict, List, Optional

from sqlalchemy.orm import Session

# Import the *local* install service helpers (CORRECT: relative import).
# This avoids accidentally importing a third-party "services" package.
from ..services.install import (  # type: ignore
    InstallError,
    StepResult,
    _build_install_plan,
    _install_pypi,
    _install_oci,
    _install_git,
    _install_zip,
    _maybe_register_gateway,
    _build_lockfile,
    _write_lockfile,
    _relpath_or_abs,
)

# Entity model (local)
from ..models import Entity
from ..db import save_entity

# Optional adapters support
try:
    from ..adapters import write_adapters  # type: ignore
except Exception:  # pragma: no cover
    write_adapters = None  # type: ignore

log = logging.getLogger("install.utils")


def install_inline_manifest(
    db: Session,  # kept for API symmetry and (now) DB persist
    uid: str,
    manifest: Dict[str, Any],
    target: str,
    source_url: Optional[str] = None,
) -> Dict[str, Any]:
    """
    Perform a full install using an inline manifest, without requiring a DB Entity.

    This function mirrors the DB-backed install flow in src/services/install.py,
    but operates entirely on the provided `manifest`. It executes artifact steps
    (pip/uv, docker, git, zip), writes adapters (if present), performs optional
    MCP-Gateway registration via `mcp_registration`, writes a lockfile, and (NEW)
    upserts the catalog Entity row so inline installs persist to the DB.

    Parameters
    ----------
    db : Session
        SQLAlchemy session.
    uid : str
        Full entity UID of the form "type:name@version" (e.g., "mcp_server:hello@0.1.0").
    manifest : Dict[str, Any]
        Inline manifest content (JSON/YAML parsed into a dict). Must minimally contain
        "type", "id", and "version".
    target : str
        Target project directory where adapters and the lockfile should be written.
    source_url : Optional[str]
        The source URL where the manifest was fetched from, for logging.

    Returns
    -------
    Dict[str, Any]
        Dictionary containing:
          - "plan": simplified plan derived from the manifest
          - "results": list of step results (artifacts, adapters, gateway registration, lockfile, catalog save)
          - "files_written": paths (relative to target) that were written
          - "lockfile": the lockfile data structure (also written to disk)

    Raises
    ------
    InstallError
        If the manifest is not a dict or missing required fields ("type", "id", "version").
    """
    # Validate minimal structure up front
    if not isinstance(manifest, dict):
        raise InstallError("Inline manifest must be a JSON object (dict).")

    mtype = (manifest.get("type") or "").strip()
    mid = (manifest.get("id") or "").strip()
    ver = (manifest.get("version") or "").strip()

    if not (mtype and mid and ver):
        raise InstallError("Inline manifest missing required keys: 'type', 'id', 'version'.")

    log.debug("inline.start", extra={"uid": uid, "source_url": source_url, "target": target})

    # Create a pseudo-entity for consistent lockfile/plan shape
    ent = Entity(uid=uid, type=mtype, name=manifest.get("name") or "", version=ver)

    # Build install plan
    plan = _build_install_plan(manifest)
    results: List[StepResult] = []
    files_written: List[str] = []

    # Ensure target directory exists
    tdir = Path(target).expanduser().resolve()
    tdir.mkdir(parents=True, exist_ok=True)

    # Artifacts
    artifacts: List[dict] = list(manifest.get("artifacts") or [])
    for idx, art in enumerate(artifacts):
        kind = (art.get("kind") or "").strip().lower()
        spec = art.get("spec") or {}
        step_name = f"artifact[{idx}]:{kind}"

        try:
            if kind == "pypi":
                results.append(_install_pypi(spec))
            elif kind == "oci":
                results.append(_install_oci(spec))
            elif kind == "git":
                results.append(_install_git(spec, tdir))
            elif kind == "zip":
                results.append(_install_zip(spec, tdir))
            else:
                results.append(StepResult(step=step_name, ok=False, stderr=f"Unsupported artifact kind: {kind}"))
            log.info("artifact.done", extra={"uid": uid, "step": step_name, "ok": results[-1].ok})
        except Exception as e:
            log.exception("Failed step %s", step_name)
            results.append(StepResult(step=step_name, ok=False, stderr=str(e)))

    # Adapters (optional)
    try:
        if write_adapters and manifest.get("adapters"):
            adapter_files = write_adapters(manifest, target=str(tdir)) or []
            files_written.extend([_relpath_or_abs(p, tdir) for p in adapter_files])
            results.append(StepResult(step="adapters.write", ok=True, extra={"count": len(adapter_files)}))
        else:
            results.append(StepResult(step="adapters.write", ok=True, extra={"skipped": True}))
    except Exception as e:
        log.exception("Adapter writing failed")
        results.append(StepResult(step="adapters.write", ok=False, stderr=str(e)))

    # MCP-Gateway registration (best-effort)
    try:
        reg_res = _maybe_register_gateway(manifest)
        if reg_res is not None:
            results.append(StepResult(step="gateway.register", ok=True, extra=reg_res))
        else:
            results.append(StepResult(step="gateway.register", ok=True, extra={"skipped": True}))
        log.info("gateway.register", extra={"uid": uid, "ok": True, "skipped": reg_res is None})
    except Exception as e:
        log.exception("Gateway registration failed")
        results.append(StepResult(step="gateway.register", ok=False, stderr=str(e)))

    # (NEW) Persist catalog entity to DB for inline installs
    # Mirrors the DB-backed flow: map manifest → Entity row via save_entity()
    try:
        save_entity(manifest, db)
        db.commit()
        log.info("catalog.save", extra={"uid": uid, "ok": True})
        results.append(StepResult(step="catalog.save", ok=True))
    except Exception as e:
        db.rollback()
        log.exception("Failed to save inline entity to DB")
        results.append(StepResult(step="catalog.save", ok=False, stderr=str(e)))

    # Lockfile
    lockfile_data = _build_lockfile(ent, manifest, artifacts)
    try:
        lf_path = _write_lockfile(tdir, lockfile_data)
        files_written.append(_relpath_or_abs(lf_path, tdir))
        results.append(StepResult(step="lockfile.write", ok=True, extra={"path": str(lf_path)}))
    except Exception as e:
        log.exception("Failed to write lockfile")
        results.append(StepResult(step="lockfile.write", ok=False, stderr=str(e)))

    log.debug("inline.end", extra={"uid": uid, "steps": [r.step for r in results]})
    return {
        "plan": plan,
        "results": [asdict(r) for r in results],
        "files_written": files_written,
        "lockfile": lockfile_data,
    }
