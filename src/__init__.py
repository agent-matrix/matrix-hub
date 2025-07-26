"""
Matrix Hub package marker.
Exports __version__ from package metadata when available.
"""

from __future__ import annotations

try:
    # Python 3.8+: importlib.metadata is stdlib
    from importlib.metadata import version, PackageNotFoundError  # type: ignore
except Exception:  # pragma: no cover
    version = None  # type: ignore
    PackageNotFoundError = Exception  # type: ignore

__all__ = ["__version__"]

def _pkg_version() -> str:
    if version is None:
        return "0.0.0"
    try:
        return version("matrix-hub")
    except PackageNotFoundError:
        # Editable installs or direct source execution
        return "0.0.0"

__version__ = _pkg_version()
