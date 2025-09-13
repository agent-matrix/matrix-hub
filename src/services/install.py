"""
Installer service for Matrix Hub.

Executes an install plan for a selected catalog entity:
- Supports artifacts: pypi (uv/pip), oci (docker pull), git (clone), zip (download+extract)
- Can write project adapters based on manifest 'adapters' entries
- Can register tools/servers with MCP-Gateway based on 'mcp_registration'
- Produces a lockfile entry and returns all files written

Design goals:
- Safe defaults, clear logs, small surface area
- Idempotent where possible (git clone dir, docker pull is idempotent, pip handled by solver)
- Best-effort external side-effects; failures are collected and reported

Note on MCP-Gateway:
- In this gateway, registering an MCP "server" is done via POST /gateways.
- Our gateway_client.register_server(server_spec) handles that mapping and transport normalization.
- There is no explicit discovery endpoint; trigger_discovery(...) is a no-op shim for compatibility.

NEW (A2A-ready, non-breaking):
- If the manifest contains manifests.a2a, we:
  • persist entity.protocols += ["a2a@<version>"] and entity.manifests["a2a"] = {...}
  • best-effort register the A2A agent via Gateway (POST /a2a)
  • optionally create a virtual server associated to that A2A agent
  • upsert a row in entity_registration (protocol='a2a') when available
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, asdict
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Union
from concurrent.futures import ThreadPoolExecutor, as_completed

import httpx
import yaml
from sqlalchemy.orm import Session

from ..models import Entity
# Optional: EntityRegistration may not exist in older deployments; guard import.
try:  # pragma: no cover
    from ..models import EntityRegistration  # type: ignore
except Exception:  # pragma: no cover
    EntityRegistration = None  # type: ignore

from ..config import settings
from src.db import save_entity

# Optional dependencies (best-effort usage)
try:
    from .adapters import write_adapters  # type: ignore
except Exception:  # pragma: no cover
    write_adapters = None  # type: ignore

# Gateway helpers (these are wrappers around the new MCPGatewayClient)
try:
    from .gateway_client import (  # type: ignore
        register_tool,
        register_server,
        register_resources,
        register_prompts,
        register_gateway,
        trigger_discovery,
        # NEW (A2A)
        register_a2a_agent,
        create_server_with_a2a,
    )
except Exception:  # pragma: no cover
    register_tool = register_server = register_resources = register_prompts = register_gateway = trigger_discovery = None  # type: ignore
    register_a2a_agent = create_server_with_a2a = None  # type: ignore

log = logging.getLogger("install")


def _normalize_sse_messages_url(base: str, transport: str) -> str:
    base = (base or "").rstrip("/")
    t = (transport or "").upper()
    if base and t == "SSE" and not base.endswith("/messages/"):
        if base.endswith("/messages"):
            base += "/"
        else:
            base += "/messages/"
    return base


def _gw_sync_worker(job: Dict[str, Any]) -> Dict[str, Any]:
    """
    Runs the Tool → Resources → Prompts → Gateway sequence for one entity.
    Returns {'uid', 'ok', 'name', 'error'(opt), 'resource_ids', 'prompt_ids'}.
    """
    from . import gateway_client as gw  # lazy import like before
    uid = job["uid"]
    tool_spec = job["tool_spec"]
    resources = job["resources"]
    prompts = job["prompts"]
    server = job["server"]
    ent_name = job["ent_name"]

    try:
        # 1) Tool
        if tool_spec:
            t_spec = {**tool_spec}
            t_spec["name"] = t_spec.get("name") or t_spec.get("id")
            gw.register_tool(t_spec, idempotent=True)

        # 2) Resources
        resource_ids: List[int] = []
        if resources:
            res_resps = gw.register_resources(resources, idempotent=True)
            resource_ids = [r.get("id") for r in res_resps if isinstance(r.get("id"), int)]

        # 3) Prompts
        prompt_ids: List[int] = []
        if prompts:
            pr_resps = gw.register_prompts(prompts, idempotent=True)
            prompt_ids = [p.get("id") for p in pr_resps if isinstance(p.get("id"), int)]

        # 4) Gateway
        base = _normalize_sse_messages_url(server.get("url") or "", server.get("transport") or "")
        gw_payload = {
            "name": server.get("name") or ent_name,
            "description": server.get("description", ""),
            "url": base,
            "associated_tools": [tool_spec.get("id")] if tool_spec.get("id") else [],
            "associated_resources": resource_ids,
            "associated_prompts": prompt_ids,
        }
        gw.register_gateway(gw_payload, idempotent=True)

        return {"uid": uid, "ok": True, "name": gw_payload["name"], "resource_ids": resource_ids, "prompt_ids": prompt_ids}
    except Exception as e:
        return {"uid": uid, "ok": False, "error": str(e), "name": server.get("name") or ent_name}


# --------------------------------------------------------------------------------------
# Errors / Result Dataclasses
# --------------------------------------------------------------------------------------

class InstallError(RuntimeError):
    """Raised for fatal install errors (invalid entity, missing manifest, etc.)."""


@dataclass
class StepResult:
    step: str
    ok: bool
    returncode: Optional[int] = None
    stdout: Optional[str] = None
    stderr: Optional[str] = None
    elapsed_secs: float = 0.0
    extra: Dict[str, Any] = None  # populated ad-hoc per step


# --------------------------------------------------------------------------------------
# Public API
# --------------------------------------------------------------------------------------

def sync_registry_gateways(db: Session) -> None:
    """
    Re-affirm registration of all *new* mcp_server entities in the MCP-Gateway,
    tracking success or errors in the database.

    Updated flow (Tool → Resources → Prompts → Gateway):
      • Uses the entity.mcp_registration JSON saved during ingest.
      • Registers tool first (idempotent), then resources/prompts to get numeric IDs,
        then registers the federated gateway (/gateways) with the associations.
    """
    # Only pick up freshly ingested MCP servers (not yet registered)
    new_servers = (
        db.query(Entity)
          .filter(
              Entity.type == "mcp_server",
              Entity.gateway_registered_at.is_(None)
          )
          .all()
    )
    if not new_servers:
        return

    # Build jobs (extract once from DB rows)
    jobs: List[Dict[str, Any]] = []
    for ent in new_servers:
        reg = getattr(ent, "mcp_registration", {}) or {}
        jobs.append({
            "uid": ent.uid,
            "ent_name": ent.name,
            "tool_spec": (reg.get("tool") or {}) if isinstance(reg, dict) else {},
            "resources": (reg.get("resources") or []) if isinstance(reg, dict) else [],
            "prompts": (reg.get("prompts") or []) if isinstance(reg, dict) else [],
            "server": (reg.get("server") or {}) if isinstance(reg, dict) else {},
        })

    # Run gateway calls concurrently (I/O-bound), keep DB writes on main thread
    max_workers = max(1, int(getattr(settings, "GATEWAY_SYNC_WORKERS", 8)))
    results: List[Dict[str, Any]] = []
    with ThreadPoolExecutor(max_workers=max_workers) as pool:
        futmap = {pool.submit(_gw_sync_worker, j): j["uid"] for j in jobs}
        for fut in as_completed(futmap):
            results.append(fut.result())

    # Persist results sequentially, per entity (same semantics as before)
    for res in results:
        uid = res["uid"]
        ent = db.get(Entity, uid)
        if not ent:
            continue
        try:
            if res.get("ok"):
                ent.gateway_registered_at = datetime.utcnow()
                if hasattr(ent, "gateway_error"):
                    ent.gateway_error = None
                db.add(ent)
                db.commit()
                log.info("✓ Federated gateway synced: %s", res.get("name"))
            else:
                if hasattr(ent, "gateway_error"):
                    ent.gateway_error = res.get("error") or "gateway sync failed"
                db.add(ent)
                db.commit()
                log.warning("⚠️ Gateway sync failed for %s: %s", uid, res.get("error"))
        except Exception:
            db.rollback()
            log.exception("DB error while recording gateway sync result for %s", uid)


def install_entity(
    db: Session,
    entity_id: str,
    version: Optional[str],
    target: str,
) -> Dict[str, Any]:
    """
    Execute the install for a given entity.

    Args:
        db: SQLAlchemy session
        entity_id: Either full uid ("type:name@1.2.3") or short ("type:name")
        version: Optional version. If provided with short id -> resolves uid = f"{id}@{version}"
        target: Project directory where adapters and lockfile are written

    Returns:
        dict: { plan, results, files_written, lockfile }
    """
    uid = _resolve_uid(db, entity_id, version)

    entity = db.get(Entity, uid)
    if not entity:
        raise InstallError(f"Entity not found: {uid}")

    manifest = _load_manifest(entity)
    if not manifest:
        raise InstallError(f"Unable to load manifest for {uid} (source_url missing or fetch failed)")

    # 1) Persist catalog record in its own transaction
    try:
        save_entity(manifest=manifest, session=db)
        db.commit()
        log.info("✔ Saved Entity[%s] to catalog DB", uid)
    except Exception:
        db.rollback()
        log.exception("💥 Failed to save Entity[%s] to DB", uid)
        raise                       # abort on DB failure

    # Compute plan
    plan = _build_install_plan(manifest)

    # Execute plan
    files_written: List[str] = []
    results: List[StepResult] = []

    # Ensure target dir exists
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
                results.append(
                    StepResult(step=step_name, ok=False, stderr=f"Unsupported artifact kind: {kind}")
                )
        except Exception as e:
            log.exception("Failed step %s", step_name)
            results.append(StepResult(step=step_name, ok=False, stderr=str(e)))

    # Adapters
    adapter_files: List[str] = []
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

    # --- NEW: Best-effort A2A registration (optional, non-breaking) ---
    try:
        a2a_steps = _handle_a2a_registration(db, uid, manifest)
        if a2a_steps:
            results.extend(a2a_steps)
    except Exception as e:  # guard against unexpected issues, keep install flowing
        log.exception("A2A registration step failed")
        results.append(StepResult(step="gateway.a2a_register", ok=False, stderr=str(e)))
    # -------------------------------------------------------------------

    # 2) Best-effort MCP-Gateway registration (won’t abort install on error)
    try:
        reg_res = _maybe_register_gateway(manifest)
        results.append(StepResult(
            step="gateway.register",
            ok=True,
            extra=reg_res or {"skipped": True},
        ))

        # --- Re-affirm gateway in MCP-Gateway for mcp_server types ---
        if manifest.get("type") == "mcp_server" and isinstance(reg_res, dict):
            gw_payload = reg_res.get("gateway")
            if isinstance(gw_payload, dict):
                try:
                    register_gateway(gw_payload, idempotent=True)
                    log.info("✓ Gateway re-affirmed in MCP-Gateway: %s", gw_payload.get("name"))
                except Exception as e:
                    log.warning(
                        "⚠️ Failed to re-affirm gateway %s: %s",
                        gw_payload.get("name"),
                        e,
                    )
        # ------------------------------------------------------------

        # Clear any previous error
        ent = db.get(Entity, uid)
        if ent and getattr(ent, "gateway_error", None):
            ent.gateway_error = None
            db.commit()
            log.info("⏹ Cleared gateway_error for Entity[%s]", uid)

    except Exception as e:
        err_txt = str(e)
        log.warning("⚠️ gateway.register failed for Entity[%s]: %s", uid, err_txt)
        results.append(StepResult(step="gateway.register", ok=False, stderr=err_txt))

        # Persist that error onto our catalog record for retry/inspection
        try:
            ent = db.get(Entity, uid)
            if ent:
                ent.gateway_error = err_txt
                db.commit()
                log.info("🏷 Tagged Entity[%s].gateway_error", uid)
        except Exception:
            db.rollback()
            log.exception("💥 Failed to write gateway_error for Entity[%s]", uid)

    # Lockfile
    lockfile_data = _build_lockfile(entity, manifest, artifacts)
    try:
        lf_path = _write_lockfile(tdir, lockfile_data)
        files_written.append(_relpath_or_abs(lf_path, tdir))
        results.append(StepResult(step="lockfile.write", ok=True, extra={"path": str(lf_path)}))
    except Exception as e:
        log.exception("Failed to write lockfile")
        results.append(StepResult(step="lockfile.write", ok=False, stderr=str(e)))

    # Shape response
    return {
        "plan": plan,
        "results": [asdict(r) for r in results],
        "files_written": files_written,
        "lockfile": lockfile_data,
    }


# --------------------------------------------------------------------------------------
# UID Resolution & Manifest Loading
# --------------------------------------------------------------------------------------

_UID_RE = re.compile(r"^(agent|tool|mcp_server):[^@]+@.+$")


def _resolve_uid(db: Session, entity_id: str, version: Optional[str]) -> str:
    """
    Convert (entity_id, version) to a full uid.

    Accepts:
    - entity_id already in uid form: "type:name@1.2.3" -> return as-is
    - entity_id short "type:name" + version provided -> return "type:name@version"

    We do not try to pick "latest" if version absent for safety.
    """
    if _UID_RE.match(entity_id):
        return entity_id
    if version:
        return f"{entity_id}@{version}"
    # If no version provided and not a uid, we cannot resolve deterministically
    raise InstallError("Version is required when 'id' is not a full uid (type:name@version).")


def _load_manifest(entity: Entity) -> Optional[Dict[str, Any]]:
    """
    Fetch and parse the manifest YAML/JSON from entity.source_url.
    """
    src = (entity.source_url or "").strip()
    if not src:
        return None
    try:
        with httpx.Client(timeout=30.0) as c:
            r = c.get(src)
            r.raise_for_status()
            text = r.text
        # Try YAML first, then JSON
        try:
            data = yaml.safe_load(text)
        except Exception:
            data = json.loads(text)
        if not isinstance(data, dict):
            return None
        return data
    except Exception:
        log.exception("Failed to load manifest from %s", src)
        return None


# --------------------------------------------------------------------------------------
# Plan builder
# --------------------------------------------------------------------------------------

def _build_install_plan(manifest: Dict[str, Any]) -> Dict[str, Any]:
    """
    Build a transparent, human-readable plan from the manifest.
    """
    plan: Dict[str, Any] = {"artifacts": [], "adapters": [], "mcp_registration": {}}

    for art in manifest.get("artifacts") or []:
        kind = (art.get("kind") or "").strip().lower()
        spec = art.get("spec") or {}
        if kind == "pypi":
            pkg = spec.get("package") or ""
            ver = spec.get("version") or ""
            plan["artifacts"].append({"kind": "pypi", "command": _pip_cmd_preview(pkg, ver)})
        elif kind == "oci":
            img = spec.get("image") or ""
            tag = spec.get("tag") or ""
            dig = spec.get("digest") or ""
            ref = f"{img}@{dig}" if dig else f"{img}:{tag}" if tag else img
            plan["artifacts"].append({"kind": "oci", "command": f"docker pull {ref}".strip()})
        elif kind == "git":
            repo = spec.get("repo") or ""
            ref = spec.get("ref") or spec.get("branch") or spec.get("tag") or ""
            plan["artifacts"].append({"kind": "git", "command": f"git clone {repo} --branch {ref} <target_dir>" if ref else f"git clone {repo} <target_dir>"})
        elif kind == "zip":
            url = spec.get("url") or ""
            plan["artifacts"].append({"kind": "zip", "command": f"curl -L {url} -o /tmp/pkg.zip && unzip /tmp/pkg.zip -d <target_dir>"})
        else:
            plan["artifacts"].append({"kind": kind, "note": "unsupported"})

    if manifest.get("adapters"):
        plan["adapters"] = list(manifest["adapters"])

    if manifest.get("mcp_registration"):
        plan["mcp_registration"] = manifest["mcp_registration"]

    # NEW: reflect A2A presence in plan (non-breaking, informational)
    a2a = (manifest.get("manifests") or {}).get("a2a")
    if isinstance(a2a, dict):
        plan["a2a"] = {
            "endpoint_url": a2a.get("endpoint_url"),
            "agent_type": a2a.get("agent_type", "jsonrpc"),
            "server": a2a.get("server", {}),
        }

    return plan


def _pip_cmd_preview(pkg: str, ver: str) -> str:
    if shutil.which("uv"):
        pkg_spec = f"{pkg}{ver}" if ver else pkg
        return f"uv pip install --system --no-cache-dir {pkg_spec}"
    # Fallback
    pkg_spec = f"{pkg}{ver}" if ver else pkg
    return f"pip install --no-cache-dir {pkg_spec}"


# --------------------------------------------------------------------------------------
# Artifact installers
# --------------------------------------------------------------------------------------

def _install_pypi(spec: Dict[str, Any]) -> StepResult:
    pkg = (spec.get("package") or "").strip()
    ver = (spec.get("version") or "").strip()  # e.g. "==1.4.2" or ">=1.0,<2"
    if not pkg:
        return StepResult(step="pypi", ok=False, stderr="missing spec.package")

    pkg_spec = f"{pkg}{ver}" if ver else pkg

    if shutil.which("uv"):
        cmd = ["uv", "pip", "install", "--system", "--no-cache-dir", pkg_spec]
    else:
        cmd = [sys.executable, "-m", "pip", "install", "--no-cache-dir", pkg_spec]

    return _run_cmd("pypi", cmd, timeout=1800)


def _install_oci(spec: Dict[str, Any]) -> StepResult:
    img = (spec.get("image") or "").strip()
    tag = (spec.get("tag") or "").strip()
    dig = (spec.get("digest") or "").strip()

    if not img:
        return StepResult(step="oci", ok=False, stderr="missing spec.image")

    if not shutil.which("docker"):
        return StepResult(step="oci", ok=False, stderr="docker not available in PATH")

    ref = f"{img}@{dig}" if dig else f"{img}:{tag}" if tag else img
    cmd = ["docker", "pull", ref]
    return _run_cmd("oci", cmd, timeout=1800, redact=[ref])


def _install_git(spec: Dict[str, Any], target_dir: Path) -> StepResult:
    repo = (spec.get("repo") or "").strip()
    ref = (spec.get("ref") or spec.get("branch") or spec.get("tag") or "").strip()
    subdir = (spec.get("dest") or spec.get("directory") or "").strip()
    if not repo:
        return StepResult(step="git", ok=False, stderr="missing spec.repo")

    if not shutil.which("git"):
        return StepResult(step="git", ok=False, stderr="git not available in PATH")

    dest = target_dir / "vendor"
    dest.mkdir(parents=True, exist_ok=True)

    # Folder name from repo
    folder = _safe_folder_name(Path(repo).stem or "repo")
    if subdir:
        folder = subdir

    clone_path = _safe_join(dest, folder)
    if clone_path.exists():
        # best-effort: git fetch + checkout if ref given
        if ref:
            cmd = ["git", "-C", str(clone_path), "fetch", "--all", "--tags"]
            fetch_res = _run_cmd("git.fetch", cmd, timeout=600)
            if not fetch_res.ok:
                return fetch_res
            cmd = ["git", "-C", str(clone_path), "checkout", ref]
            co_res = _run_cmd("git.checkout", cmd, timeout=600)
            return co_res
        return StepResult(step="git", ok=True, extra={"path": str(clone_path), "skipped": "exists"})
    else:
        cmd = ["git", "clone", repo, str(clone_path)]
        res = _run_cmd("git.clone", cmd, timeout=1800, redact=[repo])
        if res.ok and ref:
            cmd2 = ["git", "-C", str(clone_path), "checkout", ref]
            res2 = _run_cmd("git.checkout", cmd2, timeout=600)
            if not res2.ok:
                return res2
        return res


def _install_zip(spec: Dict[str, Any], target_dir: Path) -> StepResult:
    url = (spec.get("url") or "").strip()
    if not url:
        return StepResult(step="zip", ok=False, stderr="missing spec.url")

    digest = (spec.get("digest") or "").strip()
    subfolder = (spec.get("dest") or "vendor_zip").strip()

    dest = _safe_join(target_dir, subfolder)
    dest.mkdir(parents=True, exist_ok=True)

    start = time.perf_counter()
    try:
        with httpx.Client(timeout=60.0) as c:
            r = c.get(url)
            r.raise_for_status()
            content = r.content
        if digest:
            algo, _, hexval = digest.partition(":")
            algo = (algo or "sha256").lower()
            computed = hashlib.new(algo, content).hexdigest()
            if computed.lower() != (hexval or "").lower():
                return StepResult(
                    step="zip",
                    ok=False,
                    stderr=f"digest mismatch: expected {digest}, got {algo}:{computed}",
                    elapsed_secs=time.perf_counter() - start,
                )
        # Write temp and unzip
        import zipfile
        with tempfile.NamedTemporaryFile(delete=False, suffix=".zip") as tmp:
            tmp.write(content)
            tmp_path = Path(tmp.name)
        with zipfile.ZipFile(tmp_path, "r") as zf:
            zf.extractall(dest)
        tmp_path.unlink(missing_ok=True)
        return StepResult(
            step="zip", ok=True, elapsed_secs=time.perf_counter() - start, extra={"path": str(dest)}
        )
    except Exception as e:
        log.exception("zip install failed")
        return StepResult(step="zip", ok=False, stderr=str(e), elapsed_secs=time.perf_counter() - start)


# --------------------------------------------------------------------------------------
# MCP-Gateway registration (best-effort)
# --------------------------------------------------------------------------------------

def _normalize_mcp_registration(reg: Dict[str, Any]) -> Dict[str, Any]:
    """
    Light normalization to keep Gateway happy without burdening catalog authors:
      - tool.integration_type: allow 'HTTP' as alias for 'REST'
      - tool.inputSchema → tool.input_schema (alias)
      - server.transport: uppercase (client maps to gateway transports, if ever used)
      - pass through 'resources' and 'prompts' lists unmodified
    """
    out = dict(reg)

    # Tool-side tweaks
    tool = out.get("tool")
    if isinstance(tool, dict):
        itype = (tool.get("integration_type") or "").upper()
        if itype == "HTTP":
            tool["integration_type"] = "REST"
        elif itype in {"REST", "MCP"}:
            tool["integration_type"] = itype
        else:
            tool["integration_type"] = "REST"

        if "input_schema" not in tool and "inputSchema" in tool:
            tool["input_schema"] = tool["inputSchema"]

    # Server-side tweaks (we still uppercase in case others rely on it)
    server = out.get("server")
    if isinstance(server, dict) and "transport" in server:
        server["transport"] = str(server["transport"]).upper()

    return out

def _maybe_register_gateway(manifest: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    """
    Best-effort registration of tools, resources, servers, gateways, and prompts.
    Returns a dict of results & errors—never raises.
    """
    reg_raw = manifest.get("mcp_registration") or {}
    if not isinstance(reg_raw, dict) or not reg_raw:
        return None

    reg = _normalize_mcp_registration(reg_raw)
    results: Dict[str, Any] = {}

    # 1) Tools
    tool_spec = reg.get("tool")
    tool_id: Optional[Union[int, str]] = None
    if tool_spec and register_tool:
        try:
            tool_resp = register_tool(tool_spec, idempotent=True)
            results["tool"] = tool_resp
            tool_id = tool_resp.get("id") or tool_spec.get("id")
        except Exception as e:
            results["tool_error"] = str(e)

    # 2) Resources → create or lookup to get numeric IDs
    resource_specs = reg.get("resources") or []
    resource_ids: List[int] = []
    if resource_specs and register_resources:
        for r_spec in resource_specs:
            try:
                resp_list = register_resources([r_spec], idempotent=True)
                rec = resp_list[0]
                resource_ids.append(rec.get("id"))
                results.setdefault("resources", []).append(rec)
            except Exception as e:
                results.setdefault("resources_error", []).append(str(e))

    # 3) Prompts → create or lookup to get numeric IDs
    prompt_specs = reg.get("prompts") or []
    prompt_ids: List[int] = []
    if prompt_specs and register_prompts:
        for p_spec in prompt_specs:
            try:
                resp_list = register_prompts([p_spec], idempotent=True)
                rec = resp_list[0]
                prompt_ids.append(rec.get("id"))
                results.setdefault("prompts", []).append(rec)
            except Exception as e:
                results.setdefault("prompts_error", []).append(str(e))

    # 4) Server or Gateway
    server_spec = reg.get("server")
    if isinstance(server_spec, dict) and register_server:
        try:
            payload: Dict[str, Any] = {
                "name": server_spec.get("name"),
                "description": server_spec.get("description", ""),
                "associated_tools": [tool_id] if tool_id is not None else [],
                "associated_resources": resource_ids,
                "associated_prompts": prompt_ids,
            }
            url = server_spec.get("url")
            transport = (server_spec.get("transport") or "").upper()
            if url:
                url = url.rstrip("/")
                if transport == "SSE" and not url.endswith("/messages/"):
                    if url.endswith("/messages"):
                        url = f"{url}/"
                    else:
                        url = f"{url}/messages/"
                payload["url"] = url
                results["gateway"] = register_gateway(payload, idempotent=True)
            else:
                results["server"] = register_server(payload, idempotent=True)
        except Exception as e:
            # record error under the appropriate key
            if server_spec.get("url"):
                results["gateway_error"] = str(e)
            else:
                results["server_error"] = str(e)

    return results


# --------------------------------------------------------------------------------------
# A2A registration helpers (non-breaking)
# --------------------------------------------------------------------------------------

def _handle_a2a_registration(db: Session, uid: str, manifest: Dict[str, Any]) -> List[StepResult]:
    """
    If manifest.manifests.a2a exists, persist protocol + manifest on Entity and
    best-effort register with Gateway (POST /a2a) and (optionally) create a server.
    Writes an entity_registration row when available.
    """
    steps: List[StepResult] = []

    a2a = (manifest.get("manifests") or {}).get("a2a")
    if not isinstance(a2a, dict):
        return steps  # nothing to do

    ent = db.get(Entity, uid)
    if not ent:
        return steps

    # 1) Persist protocol marker + the a2a manifest (non-breaking on DB)
    try:
        version = str(a2a.get("version") or "1.0")
        proto_tag = f"a2a@{version}"
        try:
            # protocols is JSON list (added in new schema); handle missing gracefully
            protos = list(getattr(ent, "protocols", []) or [])
            if proto_tag not in protos:
                protos.append(proto_tag)
            setattr(ent, "protocols", protos)
        except Exception:
            # Column may not exist in older DBs; skip silently
            pass

        try:
            m = dict(getattr(ent, "manifests", {}) or {})
            m["a2a"] = a2a
            setattr(ent, "manifests", m)
        except Exception:
            # Column may not exist in older DBs; skip silently
            pass

        db.add(ent)
        db.commit()
    except Exception:
        db.rollback()
        log.exception("Failed to persist A2A manifest/protocol to Entity[%s]", uid)
        # non-fatal for install flow

    # 2) Register A2A with Gateway (if client is available/configured)
    if not register_a2a_agent or not getattr(settings, "MCP_GATEWAY_URL", None):
        steps.append(StepResult(step="gateway.a2a_register", ok=True, extra={"skipped": True}))
        return steps

    endpoint = a2a.get("endpoint_url")
    if not endpoint:
        steps.append(StepResult(step="gateway.a2a_register", ok=False, stderr="a2a.endpoint_url missing"))
        return steps

    payload: Dict[str, Any] = {
        "name": ent.name,  # stable, human friendly
        "endpoint_url": endpoint,
        "agent_type": a2a.get("agent_type", "jsonrpc"),
        "auth_type": (a2a.get("auth") or {}).get("type", "none"),
        "auth_value": (a2a.get("auth") or {}).get("value"),
        "tags": a2a.get("tags", []),
        "version": a2a.get("version", "1.0"),
    }

    token_override = getattr(settings, "MCP_GATEWAY_BEARER_TOKEN", None)

    # Register agent
    try:
        agent_res = register_a2a_agent(payload, idempotent=True, token=token_override)  # type: ignore
        steps.append(StepResult(step="gateway.a2a_register", ok=True, extra={"response": agent_res}))

        # optional: create a virtual server bound to the agent
        srv = a2a.get("server")
        if isinstance(srv, dict) and create_server_with_a2a:
            server_payload = dict(srv)
            # ensure association by name (the Gateway can resolve by name/id)
            assoc = list(server_payload.get("associated_a2a_agents") or [])
            if payload["name"] not in assoc:
                assoc.append(payload["name"])
            server_payload["associated_a2a_agents"] = assoc

            server_res = create_server_with_a2a(server_payload, idempotent=True, token=token_override)  # type: ignore
            steps.append(StepResult(step="gateway.a2a_server", ok=True, extra={"response": server_res}))

        # record registration success
        _upsert_entity_registration(
            db=db,
            entity_uid=uid,
            protocol="a2a",
            target=str(getattr(settings, "MCP_GATEWAY_URL", "")),
            status="registered",
            metadata={"agent": {"name": payload["name"], "endpoint_url": payload["endpoint_url"]}},
        )
    except Exception as e:
        steps.append(StepResult(step="gateway.a2a_register", ok=False, stderr=str(e)))
        _upsert_entity_registration(
            db=db,
            entity_uid=uid,
            protocol="a2a",
            target=str(getattr(settings, "MCP_GATEWAY_URL", "")),
            status="failed",
            metadata={"error": str(e)},
        )

    return steps


def _upsert_entity_registration(
    db: Session,
    *,
    entity_uid: str,
    protocol: str,
    target: str,
    status: str,
    metadata: Optional[Dict[str, Any]] = None,
) -> None:
    """
    Best-effort upsert into entity_registration (if model/table exists).
    Never raises; logs on failure.
    """
    if not EntityRegistration:
        log.debug("EntityRegistration model unavailable; skipping registration persistence.")
        return

    try:
        # Composite PK: (entity_uid, protocol, target)
        row = db.get(EntityRegistration, (entity_uid, protocol, target))  # type: ignore[arg-type]
        now = datetime.utcnow()
        if not row:
            row = EntityRegistration(  # type: ignore[call-arg]
                entity_uid=entity_uid,
                protocol=protocol,
                target=target or "",
                status=status,
                registered_at=now if status == "registered" else None,
                metadata=metadata or {},
            )
        else:
            row.status = status
            if status == "registered":
                row.registered_at = now
            if metadata:
                # merge shallowly
                try:
                    row.metadata = {**(row.metadata or {}), **metadata}
                except Exception:
                    row.metadata = metadata

        db.add(row)
        db.commit()
    except Exception:
        db.rollback()
        log.exception("Failed to upsert entity_registration for %s/%s@%s", entity_uid, protocol, target)


# --------------------------------------------------------------------------------------
# Lockfile
# --------------------------------------------------------------------------------------

def _build_lockfile(entity: Entity, manifest: Dict[str, Any], artifacts: List[Dict[str, Any]]) -> Dict[str, Any]:
    return {
        "version": 1,
        "entities": [
            {
                "id": entity.uid,
                "type": entity.type,
                "name": entity.name,
                "version": entity.version,
                "artifacts": artifacts,
                "provenance": {
                    "source_url": entity.source_url,
                },
                "adapters": list(manifest.get("adapters") or []),
            }
        ],
    }


def _write_lockfile(target_dir: Path, data: Dict[str, Any]) -> Path:
    lf = target_dir / "matrix.lock.json"
    # Merge if exists: naive overwrite for MVP
    lf.write_text(json.dumps(data, indent=2, sort_keys=True), encoding="utf-8")
    return lf


# --------------------------------------------------------------------------------------
# Process helpers
# --------------------------------------------------------------------------------------

def _run_cmd(
    step: str,
    cmd: List[str],
    *,
    timeout: int = 1800,
    cwd: Optional[Path] = None,
    env: Optional[Dict[str, str]] = None,
    redact: Optional[Iterable[str]] = None,
) -> StepResult:
    start = time.perf_counter()
    try:
        proc = subprocess.run(
            cmd,
            cwd=str(cwd) if cwd else None,
            env={**os.environ, **(env or {})},
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            text=True,
            check=False,
        )
        stdout = _truncate(proc.stdout)
        stderr = _truncate(proc.stderr)
        rc = proc.returncode
        ok = rc == 0
        # avoid leaking secrets in logs/outputs
        if redact:
            for needle in redact:
                if needle:
                    stdout = stdout.replace(needle, "****")
                    stderr = stderr.replace(needle, "****")
        return StepResult(
            step=step,
            ok=ok,
            returncode=rc,
            stdout=stdout,
            stderr=stderr,
            elapsed_secs=time.perf_counter() - start,
        )
    except subprocess.TimeoutExpired:
        return StepResult(step=step, ok=False, stderr="timeout", elapsed_secs=time.perf_counter() - start)
    except Exception as e:
        return StepResult(step=step, ok=False, stderr=str(e), elapsed_secs=time.perf_counter() - start)


def _truncate(s: Optional[str], limit: int = 64_000) -> Optional[str]:
    if s is None:
        return None
    if len(s) <= limit:
        return s
    return s[:limit] + f"\n... [truncated {len(s)-limit} bytes]"


# --------------------------------------------------------------------------------------
# Paths & safety
# --------------------------------------------------------------------------------------

def _safe_folder_name(name: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9._-]", "-", name).strip(".")
    return cleaned or "pkg"


def _safe_join(base: Path, *parts: str) -> Path:
    p = (base / Path(*parts)).resolve()
    if not str(p).startswith(str(base.resolve())):
        raise InstallError("Path traversal detected")
    return p


def _relpath_or_abs(p: Path | str, base: Path) -> str:
    pth = Path(p)
    try:
        return str(pth.resolve().relative_to(base.resolve()))
    except Exception:
        return str(pth)


# --------------------------------------------------------------------------------------
# End
# --------------------------------------------------------------------------------------
