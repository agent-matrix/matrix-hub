"""
Manifest validation utilities.

Responsibilities
- Load JSON Schemas from the repo's ./schemas directory (configurable via env).
- Validate a manifest dict against the appropriate schema based on `type`.
- Apply schema defaults (where defined) into the manifest (non-destructive).
- Return structured warnings for optional trust checks (signature/SBOM stubs).

Usage
- validate_manifest(manifest) -> dict
    Raises ValueError on schema violations. Returns possibly-normalized manifest.
- validate_manifest_with_report(manifest) -> ValidationReport
    Includes warnings & schema id used; does not swallow errors, but exposes them.

Notes
- This module intentionally *does not* perform cryptographic verification;
  `check_signature` / `check_sbom` are stubs that emit warnings you can later
  replace with real logic (cosign, Sigstore, osv-scanner, etc.).
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Mapping, MutableMapping, Optional, Tuple

from jsonschema import Draft202012Validator, ValidationError as JSONSchemaValidationError
from jsonschema.validators import extend


# --------------------------------------------------------------------------------------
# Data structures
# --------------------------------------------------------------------------------------

@dataclass
class ValidationIssue:
    level: str  # "warning" | "error"
    code: str
    message: str
    field: Optional[str] = None


@dataclass
class ValidationReport:
    is_valid: bool
    manifest: Dict[str, Any]
    schema_id: Optional[str] = None
    errors: List[ValidationIssue] = field(default_factory=list)
    warnings: List[ValidationIssue] = field(default_factory=list)


# --------------------------------------------------------------------------------------
# Schema loading and caching
# --------------------------------------------------------------------------------------

# Default schema files in the repo's ./schemas directory.
SCHEMA_FILES: Mapping[str, str] = {
    "agent": "agent.manifest.schema.json",
    "tool": "tool.manifest.schema.json",
    "mcp_server": "mcp-server.manifest.schema.json",
}

# Resolve schemas directory:
#  - VAL_SCHEMAS_DIR env var (optional)
#  - project root / "schemas" (default)
def _default_schemas_dir() -> Path:
    # src/services/validate.py -> .../src/services -> .../src -> project root
    here = Path(__file__).resolve()
    root = here.parents[2]  # matrix-hub/
    return root / "schemas"


SCHEMAS_DIR = Path(os.getenv("VAL_SCHEMAS_DIR", _default_schemas_dir()))
_SCHEMA_CACHE: Dict[str, Dict[str, Any]] = {}
_STORE_BY_ID: Dict[str, Dict[str, Any]] = {}  # for $id-based resolution


def _load_schema(path: Path) -> Dict[str, Any]:
    with path.open("r", encoding="utf-8") as f:
        data = json.load(f)
    return data


def load_schemas() -> Dict[str, Dict[str, Any]]:
    """
    Load and cache JSON Schemas. Callable at startup or lazily on first use.
    Returns a dict keyed by manifest type ('agent'|'tool'|'mcp_server').
    """
    global _SCHEMA_CACHE, _STORE_BY_ID

    if _SCHEMA_CACHE:
        return _SCHEMA_CACHE

    if not SCHEMAS_DIR.exists():
        raise FileNotFoundError(f"Schemas directory not found: {SCHEMAS_DIR}")

    for mtype, filename in SCHEMA_FILES.items():
        schema_path = SCHEMAS_DIR / filename
        if not schema_path.exists():
            raise FileNotFoundError(f"Schema file not found: {schema_path}")
        schema = _load_schema(schema_path)
        _SCHEMA_CACHE[mtype] = schema
        schema_id = schema.get("$id")
        if schema_id:
            _STORE_BY_ID[schema_id] = schema

    return _SCHEMA_CACHE


# --------------------------------------------------------------------------------------
# JSON Schema validator with defaults application
# --------------------------------------------------------------------------------------

def _extend_with_default(validator_class):
    """
    Extend a jsonschema validator to apply default values to the instance.
    This mutates the instance dict *during* validation for keys with "default".
    """
    validate_properties = validator_class.VALIDATORS.get("properties")

    def set_defaults(validator, properties, instance, schema):
        if isinstance(instance, dict):
            for prop, subschema in (properties or {}).items():
                if "default" in subschema and prop not in instance:
                    instance[prop] = subschema["default"]
        if validate_properties is not None:
            # Continue normal validation
            for error in validate_properties(validator, properties, instance, schema):
                yield error

    return extend(validator_class, {"properties": set_defaults})


DefaultingValidator = _extend_with_default(Draft202012Validator)


def _validator_for(manifest_type: str) -> Tuple[Draft202012Validator, Dict[str, Any]]:
    schemas = load_schemas()
    key = manifest_type.strip().lower()
    if key not in schemas:
        raise ValueError(f"Unknown manifest type '{manifest_type}' (expected one of {list(SCHEMA_FILES)})")
    schema = schemas[key]
    # The modern `jsonschema` prefers using a schema directly; $ref resolution will
    # work for internal references. For cross-file $id resolution, we'd need a
    # referencing registry; for now we assume local references only.
    validator = DefaultingValidator(schema)
    return validator, schema


# --------------------------------------------------------------------------------------
# Public API
# --------------------------------------------------------------------------------------

def validate_manifest(manifest: Dict[str, Any]) -> Dict[str, Any]:
    """
    Validate and normalize a manifest. Raises ValueError on invalid.

    Returns a (possibly default-enriched) manifest dict.
    """
    report = validate_manifest_with_report(manifest)
    if not report.is_valid:
        errors = "; ".join(f"{e.field or ''}{(': ' if e.field else '')}{e.message}" for e in report.errors)
        raise ValueError(f"Manifest validation failed: {errors}")
    return report.manifest


def validate_manifest_with_report(manifest: Dict[str, Any]) -> ValidationReport:
    """
    As above, but returns a structured report with warnings and schema id.
    Never mutates the caller's object (works on a shallow copy).
    """
    if not isinstance(manifest, dict):
        raise ValueError("Manifest must be a mapping/dict.")

    # Shallow copy to avoid mutating caller; defaults will be applied to this copy.
    instance: Dict[str, Any] = dict(manifest)

    mtype = str(instance.get("type") or "").strip()
    if not mtype:
        return ValidationReport(
            is_valid=False,
            manifest=instance,
            errors=[ValidationIssue(level="error", code="missing_type", message="Manifest is missing 'type'")],
        )

    try:
        validator, schema = _validator_for(mtype)
        validator.validate(instance)  # applies defaults via DefaultingValidator
        is_valid = True
        errors: List[ValidationIssue] = []
    except JSONSchemaValidationError as exc:
        is_valid = False
        errors = [
            ValidationIssue(
                level="error",
                code="schema_violation",
                message=_format_jsonschema_error(exc),
                field=".".join(str(p) for p in exc.path) or None,
            )
        ]

    # Optional trust checks (stub implementations):
    warnings: List[ValidationIssue] = []
    try:
        warnings.extend(check_signature(instance))
    except Exception as e:
        warnings.append(ValidationIssue(level="warning", code="signature_check_error", message=str(e)))

    try:
        warnings.extend(check_sbom(instance))
    except Exception as e:
        warnings.append(ValidationIssue(level="warning", code="sbom_check_error", message=str(e)))

    return ValidationReport(
        is_valid=is_valid,
        manifest=instance,
        schema_id=schema.get("$id") if is_valid else None,
        errors=errors,
        warnings=warnings,
    )


# --------------------------------------------------------------------------------------
# Trust checks (stubs) — replace with real implementations later
# --------------------------------------------------------------------------------------

def check_signature(manifest: Dict[str, Any]) -> List[ValidationIssue]:
    """
    Stub hook: inspect signature hints and return warnings.

    Heuristics:
    - If 'sig_uri' is present at the root or in artifacts but signature verification
      is not configured, emit a warning that verification is skipped.
    - If OCI/PyPI artifacts have a digest/hash field missing, warn.
    """
    warnings: List[ValidationIssue] = []

    # Root-level signature hint
    if "sig_uri" in manifest:
        warnings.append(
            ValidationIssue(
                level="warning",
                code="signature_not_verified",
                message="sig_uri present but cryptographic verification is not enabled; skipping.",
                field="sig_uri",
            )
        )

    artifacts = manifest.get("artifacts") or []
    if isinstance(artifacts, list):
        for idx, art in enumerate(artifacts):
            if not isinstance(art, dict):
                continue
            kind = str(art.get("kind") or "")
            spec = art.get("spec") or {}
            field_base = f"artifacts[{idx}]"

            # Generic signature hint
            if "sig_uri" in art:
                warnings.append(
                    ValidationIssue(
                        level="warning",
                        code="signature_not_verified",
                        message=f"{field_base}.sig_uri present but not verified; skipping.",
                        field=f"{field_base}.sig_uri",
                    )
                )

            # Digest/hash presence check for immutable references
            if kind in ("oci", "pypi", "zip", "git"):
                digest = spec.get("digest") or art.get("digest") or art.get("hash")
                if not digest and kind in ("oci", "zip"):
                    warnings.append(
                        ValidationIssue(
                            level="warning",
                            code="missing_digest",
                            message=f"{field_base} is missing an immutable digest/hash; installs may be non-reproducible.",
                            field=f"{field_base}.spec",
                        )
                    )

    return warnings


def check_sbom(manifest: Dict[str, Any]) -> List[ValidationIssue]:
    """
    Stub hook: inspect SBOM hints and return warnings.

    Heuristics:
    - If 'sbom_uri' exists, warn that no SBOM scanning is configured.
    """
    warnings: List[ValidationIssue] = []

    if "sbom_uri" in manifest:
        warnings.append(
            ValidationIssue(
                level="warning",
                code="sbom_not_scanned",
                message="sbom_uri present but SBOM scanning is not configured; skipping.",
                field="sbom_uri",
            )
        )

    artifacts = manifest.get("artifacts") or []
    if isinstance(artifacts, list):
        for idx, art in enumerate(artifacts):
            if not isinstance(art, dict):
                continue
            field_base = f"artifacts[{idx}]"
            if "sbom_uri" in art:
                warnings.append(
                    ValidationIssue(
                        level="warning",
                        code="sbom_not_scanned",
                        message=f"{field_base}.sbom_uri present but SBOM scanning is not configured; skipping.",
                        field=f"{field_base}.sbom_uri",
                    )
                )
    return warnings


# --------------------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------------------

def _format_jsonschema_error(exc: JSONSchemaValidationError) -> str:
    loc = ".".join(str(p) for p in exc.path) or "<root>"
    return f"{loc}: {exc.message}"
