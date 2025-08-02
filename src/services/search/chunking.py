# src/services/search/chunking.py
# -*- coding: utf-8 -*-
"""
Lightweight text/markdown/code chunker for indexing & RAG.

Goals
-----
- No external deps.
- Robust enough for READMEs, docs, and plain text.
- Stable, deterministic chunk IDs (hash-based) for idempotent upserts.
- Overlap control to preserve context across chunks.
- Heuristics:
    * Respect fenced code blocks as atomic blocks.
    * Prefer splitting on markdown headings, then paragraphs, then sentences.
    * Fallback to character windows if content is very long.

Public API
----------
- chunk_document(text, *, max_tokens=256, overlap_tokens=48, kind="auto", meta=None)
- split_markdown_blocks(text)   -> list[str]
- split_plain_blocks(text)      -> list[str]
- estimate_tokens(text)         -> int

Notes
-----
- Token estimation uses a simple approximation (~4 chars/token). You can
  swap this later with a real tokenizer without changing the interface.
"""

from __future__ import annotations

import hashlib
import math
import re
from dataclasses import dataclass, asdict
from typing import Dict, Iterable, List, Optional, Sequence, Tuple


__all__ = [
    "Chunk",
    "chunk_document",
    "split_markdown_blocks",
    "split_plain_blocks",
    "estimate_tokens",
]


# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class Chunk:
    """
    A single chunk of text ready for embedding/indexing.
    """
    uid: str
    order: int
    text: str
    start_char: int
    end_char: int
    tokens_est: int
    meta: Dict[str, str]

    def to_dict(self) -> Dict[str, object]:
        d = asdict(self)
        # Keep payload compact for storage/transport if needed
        return d


# ---------------------------------------------------------------------------
# Token estimation & helpers
# ---------------------------------------------------------------------------

_WHITESPACE_RE = re.compile(r"[ \t]+")

def normalize_ws(s: str) -> str:
    # Collapse horizontal whitespace but preserve line breaks
    return _WHITESPACE_RE.sub(" ", s).strip()


def estimate_tokens(text: str) -> int:
    """
    Crude but stable estimator. Many BPE tokenizers average ~3-4 chars/token
    on English text; we pick 4 to be conservative.
    """
    if not text:
        return 0
    # Quick count: favor characters; add a tiny penalty for many newlines
    penalty = text.count("\n") // 4
    return max(1, math.ceil((len(text) + penalty) / 4))


# ---------------------------------------------------------------------------
# Blockers (Markdown / Plain)
# ---------------------------------------------------------------------------

_FENCE_RE = re.compile(r"^```.*?$", re.M)  # match opening/closing fences
_HEADING_RE = re.compile(r"^(#{1,6})\s+.+$", re.M)
_HR_RE = re.compile(r"^(-{3,}|\*{3,}|_{3,})\s*$", re.M)
_TABLE_LINE_RE = re.compile(r"^\s*\|.*\|\s*$", re.M)

def split_markdown_blocks(text: str) -> List[str]:
    """
    Split markdown into logical blocks:
      - fenced code blocks kept intact
      - headings start new blocks
      - horizontal rules split
      - tables grouped
      - blank-line separated paragraphs
    """
    if not text:
        return []

    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    blocks: List[str] = []
    buf: List[str] = []

    in_fence = False
    fence_delim = ""
    i = 0
    while i < len(lines):
        line = lines[i]

        # Handle fenced code blocks
        if line.startswith("```"):
            if not in_fence:
                # flush current buffer as a block
                if buf and any(l.strip() for l in buf):
                    blocks.append("\n".join(buf).rstrip())
                    buf = []
                in_fence = True
                fence_delim = line.strip()
                buf.append(line)
            else:
                buf.append(line)
                blocks.append("\n".join(buf).rstrip())
                buf = []
                in_fence = False
                fence_delim = ""
            i += 1
            continue

        if in_fence:
            buf.append(line)
            i += 1
            continue

        # Horizontal rule -> boundary
        if _HR_RE.match(line):
            if buf and any(l.strip() for l in buf):
                blocks.append("\n".join(buf).rstrip())
                buf = []
            blocks.append(line.strip())
            i += 1
            continue

        # Headings start a new block
        if _HEADING_RE.match(line):
            if buf and any(l.strip() for l in buf):
                blocks.append("\n".join(buf).rstrip())
                buf = []
            # Include heading line alone
            blocks.append(line.rstrip())
            i += 1
            continue

        # Group tables as single block (consecutive lines starting with '|')
        if _TABLE_LINE_RE.match(line):
            if buf and any(l.strip() for l in buf):
                blocks.append("\n".join(buf).rstrip())
                buf = []
            tbl = [line]
            j = i + 1
            while j < len(lines) and _TABLE_LINE_RE.match(lines[j]):
                tbl.append(lines[j])
                j += 1
            blocks.append("\n".join(tbl).rstrip())
            i = j
            continue

        # Blank line => paragraph boundary
        if not line.strip():
            if buf and any(l.strip() for l in buf):
                blocks.append("\n".join(buf).rstrip())
                buf = []
            i += 1
            continue

        # Default: accumulate
        buf.append(line)
        i += 1

    if buf and any(l.strip() for l in buf):
        blocks.append("\n".join(buf).rstrip())

    # Drop empty artifacts, normalize some whitespace
    cleaned = [b if b.startswith("```") else normalize_ws(b) for b in blocks if b.strip()]
    return cleaned


def split_plain_blocks(text: str) -> List[str]:
    """
    Split plain text by double newlines (paragraphs). Fallback to sentence bursts.
    """
    if not text:
        return []
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    paras = [normalize_ws(p) for p in text.split("\n\n") if p.strip()]
    if paras:
        return paras
    # fallback: single-sentence blocks
    return [normalize_ws(s) for s in _split_sentences(text) if s.strip()]


# ---------------------------------------------------------------------------
# Sentence splitter (simple regex heuristic)
# ---------------------------------------------------------------------------

_SENT_END_RE = re.compile(r"(?<!\b[A-Z])[.!?][\"')\]]?\s+")  # cautious on initials/abbrev

def _split_sentences(text: str) -> List[str]:
    parts: List[str] = []
    start = 0
    for m in _SENT_END_RE.finditer(text):
        end = m.end()
        seg = text[start:end].strip()
        if seg:
            parts.append(seg)
        start = end
    tail = text[start:].strip()
    if tail:
        parts.append(tail)
    return parts


# ---------------------------------------------------------------------------
# Chunk merging
# ---------------------------------------------------------------------------

def _hash_uid(*parts: str) -> str:
    h = hashlib.sha1()
    for p in parts:
        h.update(p.encode("utf-8", "ignore"))
        h.update(b"\x00")
    return h.hexdigest()


def _merge_blocks(
    blocks: Sequence[str],
    *,
    source_id: str,
    max_tokens: int,
    overlap_tokens: int,
) -> List[Tuple[str, int, int]]:
    """
    Merge small blocks into windows under max_tokens, with overlaps.

    Returns a list of tuples: (chunk_text, start_char, end_char)
    """
    if not blocks:
        return []

    windows: List[Tuple[str, int, int]] = []
    idx = 0
    # Pre-compute char offsets into a reconstructed doc for reproducible [start,end)
    joined = "\n\n".join(blocks)
    # Build a map from block index -> char offset in joined string
    offsets: List[Tuple[int, int]] = []
    cursor = 0
    for b in blocks:
        start = cursor
        cursor = start + len(b)
        offsets.append((start, cursor))
        cursor += 2  # account for the "\n\n" that would have been joined

    while idx < len(blocks):
        cur: List[str] = []
        cur_tokens = 0
        start_char = offsets[idx][0]
        j = idx
        while j < len(blocks):
            t_est = estimate_tokens(blocks[j])
            if cur and cur_tokens + t_est > max_tokens:
                break
            cur.append(blocks[j])
            cur_tokens += t_est
            j += 1

        # If a single block is too large, hard-slice it by chars
        if not cur and idx < len(blocks):
            big = blocks[idx]
            # slice length in chars approximating tokens
            max_chars = max(1, max_tokens * 4)
            chunk_texts = _slice_hard(big, max_chars=max_chars, overlap_chars=max(0, overlap_tokens * 4))
            # compute approximate char ranges using local offsets; we only
            # guarantee stable uid via content hash, not absolute positions
            for k, part in enumerate(chunk_texts):
                s = 0 + k * (len(part) - max(0, overlap_tokens * 4))
                e = s + len(part)
                windows.append((part, start_char + s, start_char + e))
            idx += 1
            continue

        chunk_text = "\n\n".join(cur).strip()
        end_char = offsets[j - 1][1] if j - 1 < len(offsets) else start_char + len(chunk_text)
        windows.append((chunk_text, start_char, end_char))

        if j >= len(blocks):
            break

        # Overlap: move idx forward but keep some token overlap
        # Approximate by char count
        back_tokens = min(overlap_tokens, cur_tokens // 2)
        back_chars = back_tokens * 4
        # Walk backwards to find a start ensuring back_chars overlap
        # Compute length of chunk_text
        used_chars = len(chunk_text)
        new_start_rel = max(0, used_chars - back_chars)
        # Find the block index whose start >= start_char + new_start_rel
        new_abs_start = start_char + new_start_rel
        # Simple scan to find next idx
        next_idx = j
        for k in range(idx, j):
            if offsets[k][0] >= new_abs_start:
                next_idx = k
                break
        idx = max(idx + 1, min(next_idx, j))
    return windows


def _slice_hard(text: str, *, max_chars: int, overlap_chars: int) -> List[str]:
    """
    Hard-slice very long text by characters. Attempt to align on sentence
    boundaries when possible, but do not exceed max_chars.
    """
    if len(text) <= max_chars:
        return [text]

    chunks: List[str] = []
    i = 0
    while i < len(text):
        end = min(len(text), i + max_chars)
        window = text[i:end]

        # Try to trim to last sentence end inside the window
        m = list(_SENT_END_RE.finditer(window))
        if m:
            cut = m[-1].end()
            window = window[:cut].rstrip()
            end = i + cut

        if not window.strip():
            # fallback to raw slice
            window = text[i:min(len(text), i + max_chars)].strip()
            end = i + len(window)

        chunks.append(window)
        if end >= len(text):
            break

        # Overlap
        i = max(i + 1, end - max(0, overlap_chars))
    return chunks


# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

def chunk_document(
    text: str,
    *,
    source_id: str | None = None,
    kind: str = "auto",              # "auto" | "markdown" | "plain"
    max_tokens: int = 256,
    overlap_tokens: int = 48,
    meta: Optional[Dict[str, str]] = None,
) -> List[Chunk]:
    """
    Split a document into stable chunks suitable for embedding & search.

    Parameters
    ----------
    text : str
        The full document content.
    source_id : str, optional
        A stable identifier (e.g., entity uid or manifest URL). Used to derive
        chunk uid hashes. If omitted, hash is derived from content only.
    kind : str
        "markdown", "plain", or "auto" (detect fences/headings).
    max_tokens : int
        Target maximum tokens per chunk (approximate).
    overlap_tokens : int
        Overlap tokens between adjacent chunks to retain context.
    meta : dict
        Additional metadata to copy on each chunk (e.g., {"lang": "en"}).

    Returns
    -------
    List[Chunk]
    """
    if not text:
        return []

    # Decide splitter
    is_md = (kind == "markdown") or (kind == "auto" and ("```" in text or _HEADING_RE.search(text)))
    blocks = split_markdown_blocks(text) if is_md else split_plain_blocks(text)

    windows = _merge_blocks(
        blocks,
        source_id=source_id or "",
        max_tokens=max_tokens,
        overlap_tokens=overlap_tokens,
    )

    chunks: List[Chunk] = []
    for order, (payload, start_char, end_char) in enumerate(windows):
        payload = payload.strip("\n\r ")
        if not payload:
            continue
        t_est = estimate_tokens(payload)
        uid_seed = source_id or ""
        uid = _hash_uid(uid_seed, str(order), hashlib.sha1(payload.encode("utf-8")).hexdigest())
        chunks.append(
            Chunk(
                uid=uid,
                order=order,
                text=payload,
                start_char=start_char,
                end_char=end_char,
                tokens_est=t_est,
                meta=dict(meta or {}),
            )
        )
    return chunks
# --- Back-compat shim: old ingestors import split_text ------------------------
def split_text(
    text: str,
    *,
    max_tokens: int = 256,
    overlap_tokens: int = 48,
    kind: str = "auto",
    meta: dict | None = None,
):
    """
    Backward-compatible wrapper around chunk_document(...).

    Returns only the chunk texts (list[str]) to match older callers.
    New code should call chunk_document(...) and use Chunk objects.
    """
    chunks = chunk_document(
        text,
        source_id=meta.get("source_id") if isinstance(meta, dict) else None,
        kind=kind,
        max_tokens=max_tokens,
        overlap_tokens=overlap_tokens,
        meta=meta,
    )
    return [c.text for c in chunks]
