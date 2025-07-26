"""
Hybrid ranker: merge lexical and vector hits and compute a final score.

score_final = w_sem*sem + w_lex*lex + w_q*qual + w_r*rec

- Inputs are per-backend hits with normalized 'score' in [0,1] when possible.
- Quality/recency come from backends (computed or passed through).
"""

from __future__ import annotations

from typing import Dict, List

from ...config import settings
from .interfaces import Hit


def _to_map(hits: List[Hit]) -> Dict[str, Hit]:
    out: Dict[str, Hit] = {}
    for h in hits:
        eid = h["entity_id"]
        if eid not in out:
            out[eid] = dict(h)  # copy
        else:
            # Keep the better score for duplicates from the same source
            if h.get("source") == "lexical":
                out[eid]["score"] = max(float(out[eid].get("score", 0.0)), float(h["score"]))
            elif h.get("source") == "vector":
                out[eid]["score"] = max(float(out[eid].get("score", 0.0)), float(h["score"]))
    return out


def merge_and_score(lex_hits: List[Hit], vec_hits: List[Hit]) -> List[Dict]:
    w = settings.SEARCH_WEIGHTS

    lex_map = _to_map([h for h in lex_hits if h.get("source") == "lexical"])
    vec_map = _to_map([h for h in vec_hits if h.get("source") == "vector"])

    entity_ids = set(lex_map.keys()) | set(vec_map.keys())

    merged: List[Dict] = []
    for eid in entity_ids:
        lex = float(lex_map.get(eid, {}).get("score", 0.0))
        sem = float(vec_map.get(eid, {}).get("score", 0.0))
        qual = float(
            (lex_map.get(eid, {}).get("quality", 0.0) + vec_map.get(eid, {}).get("quality", 0.0)) / 2.0
        )
        rec = float(
            (lex_map.get(eid, {}).get("recency", 0.0) + vec_map.get(eid, {}).get("recency", 0.0)) / 2.0
        )

        score_final = (
            w.semantic * sem +
            w.lexical * lex +
            w.quality * qual +
            w.recency * rec
        )

        merged.append(
            {
                "entity_id": eid,
                "score_lexical": lex,
                "score_semantic": sem,
                "score_quality": qual,
                "score_recency": rec,
                "score_final": score_final,
            }
        )

    merged.sort(key=lambda x: x["score_final"], reverse=True)
    return merged
