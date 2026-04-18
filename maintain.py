"""Memory maintenance for Icarus.

Scores entries by quality, detects stale/duplicate candidates, and archives
low-value entries to cold/. All operations are heuristic-only (no LLM).
"""
from __future__ import annotations

import math
import re
import shutil
from datetime import datetime, timezone
from difflib import SequenceMatcher
from pathlib import Path
from typing import Any

from . import state

STOPWORDS = frozenset(
    "a an the is are was were be been being have has had do does did "
    "will would shall should may might can could of in to for on with "
    "at by from as into about between through after before above below "
    "and or but not no nor so yet if then than that this it its".split()
)


def _parse_entry(path: Path) -> dict:
    head = state._parse_head(path)
    body = ""
    text = path.read_text("utf-8", errors="replace")
    m = re.search(r"\n---\s*\n", text)
    if m:
        body = text[m.end():].strip()
    head["_body"] = body
    head["_path"] = str(path)
    head["_file"] = path.name
    head["_mtime"] = path.stat().st_mtime
    return head


def _age_days(entry: dict) -> float:
    ts = entry.get("timestamp")
    if not ts:
        return 999.0
    try:
        if isinstance(ts, datetime):
            dt = ts if ts.tzinfo else ts.replace(tzinfo=timezone.utc)
        else:
            from dateutil import parser
            dt = parser.parse(str(ts))
        return max(0.0, (datetime.now(timezone.utc) - dt).total_seconds() / 86400)
    except Exception:
        return 999.0


def score_entry(entry: dict, recall_count: int = 0) -> dict[str, float]:
    age = _age_days(entry)
    recency = math.exp(-age / 60)

    reuse = int(entry.get("reuse_count", 0) or 0)
    reuse_signal = min(math.log1p(reuse) / math.log1p(10), 1.0)

    recall_signal = min(recall_count / 5, 1.0)

    verified = entry.get("verified", "")
    tv = str(entry.get("training_value", "")).lower()
    if verified and str(verified).lower() not in ("", "false", "no"):
        trust = 1.0
    elif tv == "high":
        trust = 0.6
    else:
        trust = 0.3

    has_outcome = bool(entry.get("outcome", ""))
    has_evidence = bool(entry.get("evidence", ""))
    richness = 1.0 if (has_outcome and has_evidence) else (0.5 if has_outcome else 0.2)

    total = (
        0.30 * recency
        + 0.25 * recall_signal
        + 0.20 * reuse_signal
        + 0.15 * trust
        + 0.10 * richness
    )

    return {
        "quality": round(total, 3),
        "recency": round(recency, 3),
        "recall_signal": round(recall_signal, 3),
        "reuse": round(reuse_signal, 3),
        "trust": round(trust, 3),
        "richness": round(richness, 3),
        "age_days": round(age, 1),
    }


def _title_tokens(text: str) -> set[str]:
    words = re.findall(r"[a-z0-9]+", str(text).lower())
    return {w for w in words if w not in STOPWORDS and len(w) > 2}


def _jaccard(a: set, b: set) -> float:
    if not a or not b:
        return 0.0
    return len(a & b) / len(a | b)


def find_duplicates(fabric_dir: Path | None = None) -> list[dict]:
    fdir = Path(fabric_dir) if fabric_dir else state.FABRIC_DIR
    entries = []
    for f in fdir.glob("*.md"):
        if f.name.startswith("."):
            continue
        try:
            entries.append(_parse_entry(f))
        except Exception:
            continue

    candidates: list[dict] = []
    seen: set[tuple[str, str]] = set()

    for i, a in enumerate(entries):
        tokens_a = _title_tokens(a.get("summary", ""))
        if not tokens_a:
            continue
        for b in entries[i + 1:]:
            tokens_b = _title_tokens(b.get("summary", ""))
            if not tokens_b:
                continue
            title_sim = _jaccard(tokens_a, tokens_b)
            if title_sim < 0.7:
                continue
            body_a = a.get("_body", "")[:200]
            body_b = b.get("_body", "")[:200]
            body_sim = SequenceMatcher(None, body_a, body_b).ratio() if body_a and body_b else 0.0
            if body_sim < 0.3:
                continue
            key = tuple(sorted([a["_file"], b["_file"]]))
            if key in seen:
                continue
            seen.add(key)
            candidates.append({
                "entry_a": a["_file"],
                "entry_b": b["_file"],
                "title_a": a.get("summary", "")[:80],
                "title_b": b.get("summary", "")[:80],
                "title_similarity": round(title_sim, 2),
                "body_similarity": round(body_sim, 2),
                "action": "auto_merge" if body_sim > 0.8 else "review",
            })

    candidates.sort(key=lambda c: c["body_similarity"], reverse=True)
    return candidates


def find_stale(
    fabric_dir: Path | None = None,
    quality_threshold: float = 0.2,
    min_age_days: int = 30,
) -> list[dict]:
    fdir = Path(fabric_dir) if fabric_dir else state.FABRIC_DIR
    stale: list[dict] = []
    for f in fdir.glob("*.md"):
        if f.name.startswith("."):
            continue
        try:
            entry = _parse_entry(f)
        except Exception:
            continue
        scores = score_entry(entry)
        if scores["quality"] < quality_threshold and scores["age_days"] > min_age_days:
            stale.append({
                "file": entry["_file"],
                "summary": entry.get("summary", "")[:80],
                "quality": scores["quality"],
                "age_days": scores["age_days"],
                "type": entry.get("type", ""),
            })

    stale.sort(key=lambda s: s["quality"])
    return stale


def archive_entry(entry_id: str, fabric_dir: Path | None = None) -> dict:
    fdir = Path(fabric_dir) if fabric_dir else state.FABRIC_DIR
    cold = fdir / "cold"
    cold.mkdir(parents=True, exist_ok=True)

    for f in fdir.glob("*.md"):
        head = f.read_text("utf-8", errors="replace")[:400]
        m = re.search(r'^id: "?([^"\n]+)"?', head, re.MULTILINE)
        if not m or m.group(1).strip() != entry_id:
            continue

        text = f.read_text("utf-8")
        if re.search(r"^tier: .+$", text, re.MULTILINE):
            text = re.sub(r"^tier: .+$", "tier: cold", text, count=1, flags=re.MULTILINE)
        else:
            text = text.replace("\n---\n", "\ntier: cold\n---\n", 1)

        dst = cold / f.name
        dst.write_text(text, "utf-8")
        f.unlink()
        return {"status": "archived", "file": f.name, "destination": str(dst)}

    return {"error": f"entry {entry_id} not found"}


def maintenance_report(fabric_dir: Path | None = None) -> dict:
    fdir = Path(fabric_dir) if fabric_dir else state.FABRIC_DIR

    entries = []
    for f in fdir.glob("*.md"):
        if f.name.startswith("."):
            continue
        try:
            entries.append(_parse_entry(f))
        except Exception:
            continue

    scores = [score_entry(e) for e in entries]
    qualities = [s["quality"] for s in scores]

    if not qualities:
        return {"status": "empty", "total": 0}

    stale = [q for q in qualities if q < 0.2]
    healthy = [q for q in qualities if q >= 0.5]
    cold_count = sum(1 for f in (fdir / "cold").glob("*.md")) if (fdir / "cold").exists() else 0
    duplicates = find_duplicates(fdir)

    by_type: dict[str, int] = {}
    for e in entries:
        t = e.get("type", "unknown")
        by_type[t] = by_type.get(t, 0) + 1

    return {
        "status": "ok",
        "total": len(entries),
        "cold_count": cold_count,
        "quality_avg": round(sum(qualities) / len(qualities), 3),
        "quality_min": round(min(qualities), 3),
        "quality_max": round(max(qualities), 3),
        "healthy_count": len(healthy),
        "stale_count": len(stale),
        "stale_candidates": find_stale(fdir)[:10],
        "duplicate_candidates": duplicates[:10],
        "by_type": by_type,
    }
