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

NEW (non-breaking, A2A-ready):
- If a manifest contains `manifests.a2a`, we persist it to `entity.manifests["a2a"]`
  and tag `entity.protocols += ["a2a@<version>"]` when the columns exist.
  (Guards ensure older DBs without these columns continue to ingest safely.)
"""

from __future__ import annotations

import hashlib
import logging
from dataclasses import dataclass
from typing import Any, Dict, List, Optional
from urllib.parse import urljoin, urlparse

from concurrent.futures import ThreadPoolExecutor, as_completed

import httpx
import yaml
from sqlalchemy.orm import Session

from ..config import settings
from ..models import Entity
from ..db import session_scope

# Search & embedding utilities
from .search.chunking import split_text  # type: ignore
from .search.backends import embedder, vector, blobstore  # type: ignore
from ..db import save_entity

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


# ----------------------------------------------------------------------
# Internal: concurrent fetch/parse/validate (no DB work in threads)
# ----------------------------------------------------------------------
def _prefetch_manifests(manifest_urls: List[str]) -> List[tuple[str, Dict[str, Any]]]:
    """
    Fetch+parse+validate manifests concurrently. Returns list of (url, manifest).
    DB writes are intentionally NOT done here to keep Session usage single-threaded.
    """
    max_workers = max(1, int(getattr(settings, "INGEST_MAX_FETCH_WORKERS", 8)))
    results: List[tuple[str, Dict[str, Any]]] = []

    def worker(u: str) -> tuple[str, Optional[Dict[str, Any]], Optional[str], bool]:
        # (url, manifest_or_none, error_message_or_none, is_skip)
        try:
            m = _fetch_and_parse_manifest(u)
            m = _maybe_validate(m, source=u)
            return (u, m, None, False)
        except SkipManifest as sk:
            return (u, None, str(sk), True)
        except Exception as e:
            return (u, None, str(e), False)

    if not manifest_urls:
        return results

    with ThreadPoolExecutor(max_workers=max_workers) as ex:
        future_map = {ex.submit(worker, u): u for u in manifest_urls}
        for fut in as_completed(future_map):
            u = future_map[fut]
            try:
                url, manifest, err, is_skip = fut.result()
                if manifest is not None:
                    results.append((url, manifest))
                else:
                    if is_skip:
                        log.warning("ingest.skip", extra={"url": url, "reason": err})
                    else:
                        # keep parity with previous logging: log.exception on generic failure
                        log.exception("ingest.manifest.error", extra={"url": url, "reason": err})
            except Exception as e:
                # Extremely rare: failure in worker result retrieval
                log.exception("ingest.manifest.error", extra={"url": u, "reason": str(e)})

    return results


# ----------------------------------------------------------------------
# Ingest a single remote index (with detailed logging)
# ----------------------------------------------------------------------
def _indicates_sse_messages_url(url: str, transport: str) -> str:
    """Normalize SSE server URL to end with /messages/ if required."""
    normalized = url.rstrip("/")
    if transport == "SSE" and normalized:
        if normalized.endswith("/messages"):
            normalized = normalized + "/"
        elif not normalized.endswith("/messages/"):
            normalized = normalized + "/messages/"
    return normalized

def _ingest_remote(remote: str, db: Session, do_embed: bool) -> RemoteIngestResult:
    log = logging.getLogger("ingest")

    log.debug("ingest.fetch.index", extra={"remote": remote})
    index = _fetch_json(remote)
    manifest_urls = _extract_manifest_urls(index, base=remote)

    res = RemoteIngestResult(manifests_seen=len(manifest_urls))
    log.info(
        "ingest.index.parsed",
        extra={"remote": remote, "manifests_found": len(manifest_urls)},
    )

    # NEW: fetch/parse/validate manifests concurrently (network-bound)
    fetched: List[tuple[str, Dict[str, Any]]] = _prefetch_manifests(manifest_urls)

    # Process sequentially for DB safety
    for m_url, manifest in fetched:
        try:
            log.debug(
                "ingest.manifest.validated",
                extra={
                    "url": m_url,
                    "type": manifest.get("type"),
                    "id": manifest.get("id"),
                    "version": manifest.get("version"),
                },
            )

            # 1) Save the raw manifest as an Entity row (idempotent upsert)
            entity = save_entity(manifest, db)

            # --- persist protocol-native manifests (+ A2A tag) and registration (non-breaking) ---
            try:
                mani = manifest.get("manifests") or {}
                if isinstance(mani, dict) and mani:
                    # store entire 'manifests' block when column exists
                    try:
                        entity.manifests = mani  # type: ignore[attr-defined]
                    except Exception:
                        # Column may not exist yet (older deployments); ignore safely
                        pass

                    a2a = mani.get("a2a")
                    if isinstance(a2a, dict):
                        ver = str(a2a.get("version") or "1.0").strip()
                        tag = f"a2a@{ver}"
                        try:
                            current = list(getattr(entity, "protocols", []) or [])  # type: ignore[attr-defined]
                            if tag not in current:
                                # Sort for stable UI; tolerate duplicates via set
                                entity.protocols = sorted(set([*current, tag]))  # type: ignore[attr-defined]
                        except Exception:
                            # Column may not exist yet; ignore safely
                            pass
            except Exception:
                # Never fail ingest because of optional A2A persistence
                log.exception("ingest.a2a.persist.error", extra={"uid": getattr(entity, "uid", None)})

            # --- persist MCP registration for later sync (kept as-is) ---
            if isinstance(manifest.get("mcp_registration"), dict):
                entity.mcp_registration = manifest["mcp_registration"]  # type: ignore[attr-defined]

            db.add(entity)

            log.info(
                "ingest.entity.saved",
                extra={"uid": getattr(entity, "uid", None), "source_url": m_url},
            )

            # 2) Then continue with field‐mapping & enrichment (also sets source_url)
            entity = _upsert_entity_from_manifest(manifest, db=db, source_url=m_url)
            log.debug("ingest.entity.upserted", extra={"uid": getattr(entity, "uid", None)})

            res.entities_upserted += 1

            # 3) Optional chunk+embed path
            if do_embed:
                emb_count = _chunk_and_embed(entity=entity, manifest=manifest, db=db)
                res.embeddings_upserted += emb_count
                log.info(
                    "ingest.embed",
                    extra={"uid": getattr(entity, "uid", None), "chunks": emb_count},
                )

            # 4) Optional: re-register federated gateway in MCP-Gateway for mcp_server
            try:
                if manifest.get("type") == "mcp_server":
                    # For federated MCP servers, register a Gateway (POST /gateways)
                    from .gateway_client import register_gateway  # local import to avoid hard dep

                    reg = (manifest or {}).get("mcp_registration") or {}
                    server = reg.get("server") or {}

                    name = server.get("name") or (manifest.get("name") or manifest.get("id"))
                    description = server.get("description") or ""
                    url = (server.get("url") or "").strip()
                    transport = (server.get("transport") or "").upper()
                    if url:
                        url = _indicates_sse_messages_url(url, transport)

                    if url:
                        try:
                            register_gateway(
                                {
                                    "name": name,
                                    "description": description,
                                    "url": url,
                                },
                                idempotent=True,
                            )
                            log.info(
                                "ingest.gateway.register",
                                extra={
                                    "uid": getattr(entity, "uid", None),
                                    "name": name,
                                    "ok": True,
                                },
                            )
                        except Exception as e:  # best-effort; do not fail ingest
                            log.warning(
                                "ingest.gateway.register.error %s",
                                e,
                                extra={"uid": getattr(entity, "uid", None), "name": name},
                            )
                    else:
                        log.debug(
                            "ingest.gateway.skip",
                            extra={"uid": getattr(entity, "uid", None), "reason": "no server.url"},
                        )
            except Exception:
                # Never break ingest due to gateway registration
                log.exception(
                    "ingest.gateway.unexpected",
                    extra={"uid": getattr(entity, "uid", None), "url": m_url},
                )

        except SkipManifest as sk:
            log.warning("ingest.skip", extra={"url": m_url, "reason": str(sk)})
        except Exception:
            log.exception("ingest.manifest.error", extra={"url": m_url})

    # Commit at the end to persist everything we did
    try:
        db.commit()
        log.info(
            "ingest.commit",
            extra={
                "remote": remote,
                "entities_upserted": res.entities_upserted,
                "embeddings_upserted": res.embeddings_upserted,
            },
        )
    except Exception:
        db.rollback()
        log.exception("ingest.commit.error", extra={"remote": remote})
        raise

    return res


# ----------------- Manifest fetch/parse/validate -----------------

def _fetch_json(url: str) -> Dict[str, Any]:
    # Enable HTTP/2 for better multiplexing with some hosts (minor perf win)
    with httpx.Client(timeout=20.0, http2=True) as client:
        r = client.get(url)
        r.raise_for_status()
        return r.json()


def _fetch_text(url: str) -> str:
    with httpx.Client(timeout=20.0, http2=True) as client:
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
        from .validate import validate_manifest  # type: ignore
    except Exception:
        log.debug("Validation module not available; skipping schema validation for %s", source)
        return manifest

    try:
        return validate_manifest(manifest)
    except Exception as e:
        # Improved check: Instead of matching error strings, check the condition directly.
        is_server = manifest.get("type") == "mcp_server"
        artifacts_are_empty = not (manifest.get("artifacts") or [])

        if is_server and artifacts_are_empty:
            # This is likely the cause of the validation error.
            # We log it and proceed, as servers can have empty artifacts.
            log.warning(
                "Ignoring likely empty-artifact validation error for mcp_server: %s", source
            )
            return manifest

        # For all other errors, or for non-server types, raise to skip.
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

    # Note: Protocols/manifests are handled earlier when we have the whole manifest to inspect.

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

    if getattr(entity, "capabilities", None):
        parts.append("Capabilities: " + ", ".join(entity.capabilities))
    if getattr(entity, "frameworks", None):
        parts.append("Frameworks: " + ", ".join(entity.frameworks))
    if getattr(entity, "providers", None):
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

    chunks = split_text(corpus)  # might return str, dict, or object with .text

    # Normalize all chunks into plain strings
    texts: list[str] = []
    for c in chunks:
        if isinstance(c, dict):
            txt = c.get("text", "")
        elif hasattr(c, "text"):
            txt = str(c.text)
        else:
            txt = str(c)
        texts.append(txt)

    # Now we can safely encode
    vecs = embedder.encode(texts)

    # First, delete stale vectors for this entity (idempotent replace)
    try:
        vector.delete_vectors([entity.uid])
    except Exception:
        pass

    upserts: List[Dict[str, Any]] = []
    for (c, v), txt in zip(zip(chunks, vecs), texts):
        # Determine chunk_id
        if isinstance(c, dict):
            chunk_id = c.get("id")
        elif hasattr(c, "id"):
            chunk_id = getattr(c, "id")
        else:
            # fallback to index-based or hash
            chunk_id = hashlib.sha256(txt.encode("utf-8")).hexdigest()

        blob_key = blobstore.put_text(f"{entity.uid}#{chunk_id}", txt)
        upserts.append({
            "entity_uid": entity.uid,
            "chunk_id": str(chunk_id),
            "vector": v,
            "caps_text": ",".join(getattr(entity, "capabilities", []) or []),
            "frameworks_text": ",".join(getattr(entity, "frameworks", []) or []),
            "providers_text": ",".join(getattr(entity, "providers", []) or []),
            "quality_score": float(getattr(entity, "quality_score", 0.0) or 0.0),
            "embed_model": getattr(embedder, "model_id", "unknown"),
            "raw_ref": blob_key,
        })

    vector.upsert_vectors(upserts)
    db.flush()
    log.info("Embedded %d chunks for %s", len(upserts), entity.uid)
    return len(upserts)

def ingest_manifest(manifest: Dict[str, Any], db: Session, do_embed: bool = True) -> Entity:
    """
    Ingest a single manifest dict (e.g., from a remote index.json or a raw dict).
    Returns the upserted Entity.
    """
    source_url = manifest.get("source_url") or manifest.get("manifest_url")
    entity = _upsert_entity_from_manifest(manifest, db=db, source_url=source_url)

    # Persist protocol-native manifests (+ A2A tag) when present (non-breaking guards)
    try:
        mani = manifest.get("manifests") or {}
        if isinstance(mani, dict) and mani:
            try:
                entity.manifests = mani  # type: ignore[attr-defined]
            except Exception:
                pass
            a2a = mani.get("a2a")
            if isinstance(a2a, dict):
                ver = str(a2a.get("version") or "1.0").strip()
                tag = f"a2a@{ver}"
                try:
                    current = list(getattr(entity, "protocols", []) or [])  # type: ignore[attr-defined]
                    if tag not in current:
                        entity.protocols = sorted(set([*current, tag]))  # type: ignore[attr-defined]
                except Exception:
                    pass
        db.add(entity)
        db.flush()
    except Exception:
        log.exception("ingest.single.a2a.persist.error", extra={"uid": getattr(entity, "uid", None)})

    if do_embed:
        _chunk_and_embed(entity=entity, manifest=manifest, db=db)

    return entity


# ----------------------------------------------------------------------
# Entry points for the API layer to consume
# ----------------------------------------------------------------------
def ingest_index(db: Session, index_url: str) -> Dict[str, Any]:
    """Entry point expected by the /ingest endpoint: Ingest a remote index.json URL."""
    log = logging.getLogger("ingest")
    log.info("ingest.start", extra={"remote": index_url})
    try:
        res = _ingest_remote(index_url, db=db, do_embed=True)
        log.info(
            "ingest.end",
            extra={
                "remote": index_url,
                "manifests": getattr(res, "manifests_seen", None),
                "entities_upserted": getattr(res, "entities_upserted", None),
                "embeddings_upserted": getattr(res, "embeddings_upserted", None),
            },
        )
        return res
    except Exception:
        log.exception("ingest.error", extra={"remote": index_url})
        raise


# alias for backward-compatibility
ingest_remote = ingest_index
