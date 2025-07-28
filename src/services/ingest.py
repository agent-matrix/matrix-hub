"""
Catalog ingestion pipeline.

Responsibilities:
- Pull remote `index.json` files listed in settings.CATALOG_REMOTES
- For each manifest, fetch & validate, then upsert an Entity (idempotent by (type,id,version))
- Optionally chunk + embed text (corpus: name/desc/README/examples) and upsert vectors
- Store long text (README/chunks) in BlobStore

The shape of `index.json` can vary; we support a few simple forms:
  A) {"manifests": ["https://.../agent.manifest.yaml", ...]}
  B) {"items": [{"manifest_url": "...", ...}, ...]}
  C) {"entries": [{"path": ".../agent.manifest.yaml", "base_url": "https://raw..."}]}

Validation is delegated to services.validate (if available). If validation fails,
we log and skip the item rather than abort the entire ingest.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Any, Dict, List, Optional
from urllib.parse import urljoin, urlparse

import httpx
import yaml
from sqlalchemy.orm import Session

from ..config import settings
from ..models import Entity
from ..db import session_scope

# Search & embedding utilities
from .search.chunking import split_text  # type: ignore
from .search.backends import embedder, vector, blobstore  # type_ignore

log = logging.getLogger("ingest")


# ----------------- Public API -----------------

@dataclass
class IngestStats:
    remotes: int = 0
    manifests_seen: int = 0
    entities_upserted: int = 0
    embeddings_upserted: int = 0
    errors: int = 0


def ingest_all(remotes: Optional[List[str]] = None, do_embed: bool = True) -> IngestStats:
    """
    Ingest all configured remotes. Can be called by the scheduler or manually.
    """
    remotes = remotes or settings.CATALOG_REMOTES or []
    stats = IngestStats(remotes=len(remotes))
    if not remotes:
        log.info("No remotes configured (CATALOG_REMOTES empty). Skipping ingest.")
        return stats

    with session_scope() as db:
        for remote in remotes:
            try:
                rs = _ingest_remote(remote, db=db, do_embed=do_embed)
                stats.manifests_seen += rs.manifests_seen
                stats.entities_upserted += rs.entities_upserted
                stats.embeddings_upserted += rs.embeddings_upserted
            except Exception:
                stats.errors += 1
                log.exception("Ingest failed for remote: %s", remote)

    log.info(
        "Ingest summary: remotes=%d manifests=%d entities=%d embed=%d errors=%d",
        stats.remotes, stats.manifests_seen, stats.entities_upserted, stats.embeddings_upserted, stats.errors
    )
    return stats


# ----------------- Remote ingest -----------------

@dataclass
class RemoteIngestResult:
    manifests_seen: int = 0
    entities_upserted: int = 0
    embeddings_upserted: int = 0


def _ingest_remote(remote: str, db: Session, do_embed: bool) -> RemoteIngestResult:
    log.info("Fetching index.json from %s", remote)
    index = _fetch_json(remote)
    manifest_urls = _extract_manifest_urls(index, base=remote)
    res = RemoteIngestResult(manifests_seen=len(manifest_urls))

    for m_url in manifest_urls:
        try:
            manifest = _fetch_and_parse_manifest(m_url)
            manifest = _maybe_validate(manifest, source=m_url)
            entity = _upsert_entity_from_manifest(manifest, db=db, source_url=m_url)
            res.entities_upserted += 1

            if do_embed:
                emb_count = _chunk_and_embed(entity=entity, manifest=manifest, db=db)
                res.embeddings_upserted += emb_count
        except SkipManifest as sk:
            log.warning("Skipping manifest: %s (%s)", m_url, sk)
        except Exception:
            log.exception("Failed handling manifest: %s", m_url)
    return res


# ----------------- Manifest fetch/parse/validate -----------------

def _fetch_json(url: str) -> Dict[str, Any]:
    with httpx.Client(timeout=20.0) as client:
        r = client.get(url)
        r.raise_for_status()
        return r.json()


def _fetch_text(url: str) -> str:
    with httpx.Client(timeout=20.0) as client:
        r = client.get(url)
        r.raise_for_status()
        return r.text


def _extract_manifest_urls(index: Dict[str, Any], base: Optional[str]) -> List[str]:
    """
    Return a list of absolute manifest URLs from an index structure.
    """
    urls: List[str] = []

    # Form A: {"manifests": ["https://...yaml", "https://...yaml", ...]}
    if isinstance(index.get("manifests"), list):
        for u in index["manifests"]:
            if isinstance(u, str):
                urls.append(_abs_url(u, base))

    # Form B: {"items": [{"manifest_url": "..."}, ...]}
    if isinstance(index.get("items"), list):
        for it in index["items"]:
            if isinstance(it, dict) and isinstance(it.get("manifest_url"), str):
                urls.append(_abs_url(it["manifest_url"], base))

    # Form C: {"entries": [{"path": ".../agent.manifest.yaml", "base_url": "..."}, ...]}
    if isinstance(index.get("entries"), list):
        for it in index["entries"]:
            if isinstance(it, dict):
                path = it.get("path")
                b = it.get("base_url") or base
                if isinstance(path, str):
                    urls.append(_abs_url(path, b))

    # Deduplicate while preserving order
    seen = set()
    out: List[str] = []
    for u in urls:
        if u not in seen:
            out.append(u)
            seen.add(u)
    return out


def _abs_url(path_or_url: str, base: Optional[str]) -> str:
    if urlparse(path_or_url).scheme:  # already absolute
        return path_or_url
    return urljoin(base or "", path_or_url)


def _fetch_and_parse_manifest(url: str) -> Dict[str, Any]:
    text = _fetch_text(url)
    try:
        data = yaml.safe_load(text)
        if not isinstance(data, dict):
            raise ValueError("manifest is not a mapping")
        return data
    except Exception as e:
        raise SkipManifest(f"Invalid YAML: {e}") from e


def _maybe_validate(manifest: Dict[str, Any], source: str) -> Dict[str, Any]:
    """
    Try to validate via services.validate.validate_manifest(manifest),
    but don't hard-fail if validation isn't wired yet.
    """
    try:
        from .validate import validate_manifest  # type_ignore
    except Exception:
        log.debug("Validation module not available; skipping schema validation for %s", source)
        return manifest

    try:
        return validate_manifest(manifest)
    except Exception as e:
        raise SkipManifest(f"Schema validation failed: {e}") from e


# ----------------- Upsert entity -----------------

class SkipManifest(RuntimeError):
    """Signal to skip an individual manifest without aborting the remote."""


def _entity_uid(manifest: Dict[str, Any]) -> str:
    mtype = (manifest.get("type") or "").strip()
    mid = (manifest.get("id") or "").strip()
    ver = (manifest.get("version") or "").strip()
    if not (mtype and mid and ver):
        raise SkipManifest("Missing one of required keys: type, id, version")
    return f"{mtype}:{mid}@{ver}"


def _upsert_entity_from_manifest(manifest: Dict[str, Any], db: Session, source_url: Optional[str]) -> Entity:
    uid = _entity_uid(manifest)
    e = db.get(Entity, uid)
    if not e:
        e = Entity(uid=uid, type=manifest.get("type"), name=manifest.get("name") or "", version=manifest.get("version") or "")
        db.add(e)

    # Map fields
    e.summary = manifest.get("summary") or manifest.get("description") or e.summary
    e.description = manifest.get("description") or e.description
    e.license = manifest.get("license") or e.license
    e.homepage = manifest.get("homepage") or e.homepage
    e.source_url = source_url or e.source_url

    e.capabilities = list(manifest.get("capabilities") or []) or e.capabilities
    comp = manifest.get("compatibility") or {}
    e.frameworks = list(comp.get("frameworks") or []) or e.frameworks
    e.providers = list(comp.get("providers") or []) or e.providers

    # Optional release timestamp if present
    # (leave to default otherwise)
    db.flush()  # ensure PK is set for FK uses
    return e


# ----------------- Chunk + embed -----------------

def _build_corpus(entity: Entity, manifest: Dict[str, Any]) -> str:
    """
    Build a single string corpus from core fields + README/examples.
    """
    parts: List[str] = []
    parts.append(entity.name or "")
    parts.append(entity.summary or "")
    parts.append(entity.description or "")

    if entity.capabilities:
        parts.append("Capabilities: " + ", ".join(entity.capabilities))
    if entity.frameworks:
        parts.append("Frameworks: " + ", ".join(entity.frameworks))
    if entity.providers:
        parts.append("Providers: " + ", ".join(entity.providers))

    # README can be inline or a URL
    readme_text = ""
    readme_inline = manifest.get("readme")
    if isinstance(readme_inline, str) and readme_inline.strip():
        readme_text = readme_inline
    readme_url = manifest.get("readme_url")
    if not readme_text and isinstance(readme_url, str) and readme_url.strip():
        try:
            readme_text = _fetch_text(readme_url)
        except Exception:
            log.warning("Could not fetch readme_url=%s for %s", readme_url, entity.uid)

    if readme_text:
        parts.append(readme_text)

    # Optional usage examples (if present)
    examples = manifest.get("examples")
    if isinstance(examples, list):
        for ex in examples:
            if isinstance(ex, str):
                parts.append(ex)

    return "\n\n".join([p for p in parts if p])


def _chunk_and_embed(entity: Entity, manifest: Dict[str, Any], db: Session) -> int:
    """
    Split corpus into chunks, embed, and upsert to vector index (embedding_chunk table).
    """
    corpus = _build_corpus(entity, manifest)
    if not corpus.strip():
        return 0

    chunks = split_text(corpus)  # Each chunk: object with .id and .text (or dict-like)
    vecs = embedder.encode([getattr(c, "text", c["text"]) for c in chunks])

    # First, delete stale vectors for this entity (idempotent replace)
    try:
        vector.delete_vectors([entity.uid])  # might be a no-op if backend uses FK cascade
    except Exception:
        # Best-effort clean; not fatal
        pass

    upserts: List[Dict[str, Any]] = []
    for c, v in zip(chunks, vecs):
        chunk_id = getattr(c, "id", c.get("id"))
        text_ = getattr(c, "text", c.get("text"))
        blob_key = blobstore.put_text(f"{entity.uid}#{chunk_id}", text_ or "")
        upserts.append(
            dict(
                entity_uid=entity.uid,
                chunk_id=str(chunk_id),
                vector=v,
                caps_text=",".join(entity.capabilities or []),
                frameworks_text=",".join(entity.frameworks or []),
                providers_text=",".join(entity.providers or []),
                quality_score=float(entity.quality_score or 0.0),
                embed_model=getattr(embedder, "model_id", "unknown"),
                raw_ref=blob_key,
            )
        )

    vector.upsert_vectors(upserts)
    db.flush()  # ensure updated_at updated by DB default/onupdate
    log.info("Embedded %d chunks for %s", len(upserts), entity.uid)
    return len(upserts)
