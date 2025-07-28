"""
Project adapters writer.

- Consumes `manifest["adapters"]` entries (array of adapter specs).
- Renders tiny framework glue files (e.g., LangGraph node, WXO skill stub).
- Writes files into the target project and (optionally) appends a note to
  an existing `matrix.lock.json`.

Adapter spec (as ingested from manifests):

{
  "framework": "langgraph" | "watsonx_orchestrate" | "...",
  "template_key": "langgraph-node" | "wxo-skill",
  "path": "src/flows/pdf_summarizer_node.py",           # optional; defaults applied
  "min_version": "0.1.0",                               # optional
  "params": { "class_name": "...", "endpoint": "...", "output_key": "..." }
}

Return:
    List[str] -> absolute paths of files written
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Dict, Iterable, List



# --------------------------------------------------------------------------------------
# Public API
# --------------------------------------------------------------------------------------

def write_adapters(manifest: Dict[str, Any], *, target: str) -> List[str]:
    """
    Render + write adapter files defined in manifest["adapters"].

    If a `matrix.lock.json` exists in `target`, append the list of adapter files
    under a top-level key "adapters_files" (unique, sorted).

    Args:
        manifest: parsed manifest dict
        target:   project directory (str path)

    Returns:
        List of absolute paths written.
    """
    adapters = list(manifest.get("adapters") or [])
    if not adapters:
        return []

    target_dir = Path(target).expanduser().resolve()
    target_dir.mkdir(parents=True, exist_ok=True)

    written: List[Path] = []
    for spec in adapters:
        if not isinstance(spec, dict):
            continue
        fw = str(spec.get("framework", "")).strip().lower()
        key = str(spec.get("template_key", "")).strip().lower()
        params = dict(spec.get("params") or {})

        # Destination path
        dest = _resolve_dest_path(manifest, spec, target_dir)

        # Ensure parent dir exists
        dest.parent.mkdir(parents=True, exist_ok=True)

        # Render content based on framework/key
        content = _render_template(fw, key, manifest, params)

        # Write file (overwrite by default; these are generated adapters)
        dest.write_text(content, encoding="utf-8")
        written.append(dest)

        # For convenience, write a README.md next to WXO skill.yaml with a tiny note
        if fw in {"watsonx_orchestrate", "wxo"} and dest.name.endswith((".yaml", ".yml")):
            (dest.parent / "README.md").write_text(_WATSONX_README, encoding="utf-8")

    # Append to lockfile only if it already exists (non-destructive to installer flow)
    _append_adapters_to_lockfile(target_dir, [str(p) for p in written])

    return [str(p) for p in written]


# --------------------------------------------------------------------------------------
# Rendering
# --------------------------------------------------------------------------------------

def _render_template(framework: str, key: str, manifest: Dict[str, Any], params: Dict[str, Any]) -> str:
    if framework == "langgraph" and key in {"langgraph-node", "node"}:
        return _render_langgraph_node(manifest, params)
    if framework in {"watsonx_orchestrate", "wxo"} and key in {"wxo-skill", "skill"}:
        return _render_wxo_skill(manifest, params)

    # Fallback generic template
    name = manifest.get("name") or manifest.get("id", "adapter")
    return f"# Generated adapter for {framework}:{key}\n# {name}\n"


def _render_langgraph_node(manifest: Dict[str, Any], params: Dict[str, Any]) -> str:
    class_name = params.get("class_name") or _safe_class_name(manifest.get("name") or manifest.get("id") or "AgentNode")
    endpoint = params.get("endpoint") or (manifest.get("endpoints", {}) or {}).get("invoke") or "http://localhost:8000/invoke"
    output_key = params.get("output_key") or "result"

    return f'''# Auto-generated LangGraph node for "{manifest.get("name", manifest.get("id","agent"))}"
from typing import Dict, Any
import os
import httpx

# Endpoint can be overridden via env var if desired
DEFAULT_ENDPOINT = os.getenv("AGENT_ENDPOINT", "{endpoint}")

class {class_name}:
    """
    Minimal callable node. Expects 'input' in the state; writes '{output_key}'.
    """

    def __init__(self, endpoint: str | None = None, timeout: float = 30.0):
        self.endpoint = (endpoint or DEFAULT_ENDPOINT).rstrip("/")
        self.timeout = timeout

    def __call__(self, state: Dict[str, Any]) -> Dict[str, Any]:
        payload = {{"input": state.get("input")}}
        with httpx.Client(timeout=self.timeout) as c:
            r = c.post(f"{{self.endpoint}}/invoke", json=payload)
            r.raise_for_status()
            out = r.json()
        state["{output_key}"] = out
        return state
'''


def _render_wxo_skill(manifest: Dict[str, Any], params: Dict[str, Any]) -> str:
    # Minimal skill schema skeleton suitable for import into watsonx Orchestrate
    # Users will likely update this manually after generation.
    name = manifest.get("name") or manifest.get("id", "agent")
    title = params.get("title") or f"{name} Skill"
    description = params.get("description") or (manifest.get("summary") or manifest.get("description") or name)
    # Endpoint where the skill should POST
    url = params.get("url") or (manifest.get("endpoints", {}) or {}).get("invoke") or "http://localhost:8000/invoke"

    return f'''# yaml-language-server: $schema=https://raw.githubusercontent.com/ibm-granite/watsonx-orchestrate-schema/main/skill.schema.json
version: 1
schema_version: 1
metadata:
  id: {_safe_id(manifest.get("id") or name)}
  name: "{title}"
  description: "{_yaml_escape(description)}"
  author: "matrix-hub"
  tags: [{", ".join(_yaml_list(manifest.get("capabilities") or []))}]
  homepage: "{manifest.get("homepage","")}"
runtime:
  type: "http"
  method: "POST"
  url: "{url}"
  headers:
    Content-Type: "application/json"
inputs:
  - name: "input"
    type: "string"
    required: true
outputs:
  - name: "result"
    type: "object"
'''


_WATSONX_README = """\
# WatsonX Orchestrate Skill (generated)

This folder contains a minimal `skill.yaml` generated by Matrix Hub. 
Import it into WatsonX Orchestrate and adjust metadata/inputs/outputs to your needs.
"""


# --------------------------------------------------------------------------------------
# Dest path helpers
# --------------------------------------------------------------------------------------

def _resolve_dest_path(manifest: Dict[str, Any], spec: Dict[str, Any], target_dir: Path) -> Path:
    # Prefer explicit "path"
    custom_path = spec.get("path")
    if isinstance(custom_path, str) and custom_path.strip():
        return (target_dir / custom_path).resolve()

    fw = str(spec.get("framework", "")).strip().lower()
    key = str(spec.get("template_key", "")).strip().lower()
    base_name = _safe_file_stem(manifest.get("id") or manifest.get("name") or "adapter")

    if fw == "langgraph" and key in {"langgraph-node", "node"}:
        return (target_dir / "src" / "flows" / f"{base_name}_node.py").resolve()

    if fw in {"watsonx_orchestrate", "wxo"} and key in {"wxo-skill", "skill"}:
        return (target_dir / "skills" / base_name / "skill.yaml").resolve()

    # Generic fallback
    return (target_dir / "adapters" / f"{base_name}_{fw}_{key}.txt").resolve()


def _safe_file_stem(name: str) -> str:
    import re
    return re.sub(r"[^a-zA-Z0-9._-]+", "_", name).strip("._") or "adapter"


def _safe_class_name(name: str) -> str:
    import re
    cleaned = re.sub(r"[^a-zA-Z0-9]+", " ", name).title().replace(" ", "")
    if not cleaned or not cleaned[0].isalpha():
        cleaned = f"A{cleaned}"
    return cleaned


def _safe_id(name: str) -> str:
    return _safe_file_stem(name).lower()


def _yaml_escape(text: str) -> str:
    # simple escape for quotes/newlines
    return (text or "").replace('"', "'").replace("\n", " ").strip()


def _yaml_list(items: Iterable[str]) -> List[str]:
    return [str(x).strip() for x in items if str(x).strip()]


# --------------------------------------------------------------------------------------
# Lockfile updates
# --------------------------------------------------------------------------------------

def _append_adapters_to_lockfile(target_dir: Path, files: List[str]) -> None:
    if not files:
        return
    lock = target_dir / "matrix.lock.json"
    if not lock.exists():
        return
    try:
        data = json.loads(lock.read_text(encoding="utf-8") or "{}")
    except Exception:
        return

    existing = set(data.get("adapters_files") or [])
    for f in files:
        existing.add(str(Path(f).resolve()))

    data["adapters_files"] = sorted(existing)
    lock.write_text(json.dumps(data, indent=2, sort_keys=True), encoding="utf-8")
