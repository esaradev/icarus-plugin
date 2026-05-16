"""Redaction helpers for training export and upload guardrails."""

from __future__ import annotations

import copy
import re
from collections import Counter
from typing import Any

SECRET_PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    ("openai_key", re.compile(r"\bsk-[A-Za-z0-9_-]{20,}\b")),
    ("together_key", re.compile(r"\btgp_[A-Za-z0-9_-]{20,}\b")),
    ("github_token", re.compile(r"\bgh[pousr]_[A-Za-z0-9_]{20,}\b")),
    ("aws_access_key", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    (
        "generic_secret_assignment",
        re.compile(
            r"(?i)\b(api[_-]?key|secret|token|password|passwd)\s*[:=]\s*['\"]?[^\s,'\"]{8,}"
        ),
    ),
    ("email", re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b")),
    ("customer_id", re.compile(r"\b(cus|cust|customer)[_-]?[A-Za-z0-9]{5,}\b", re.I)),
    ("absolute_path", re.compile(r"(?<!\w)(?:/[A-Za-z0-9._+@%-]+){2,}")),
    ("windows_path", re.compile(r"\b[A-Za-z]:\\(?:[^\\\r\n]+\\?)+")),
]

DO_NOT_TRAIN_TAGS = {"do-not-train", "no-train", "private", "secret", "sensitive"}


def _mask(kind: str) -> str:
    return f"[REDACTED:{kind}]"


def redact_text(text: str) -> tuple[str, Counter]:
    counts: Counter = Counter()
    redacted = text or ""
    for kind, pattern in SECRET_PATTERNS:
        redacted, n = pattern.subn(_mask(kind), redacted)
        if n:
            counts[kind] += n
    return redacted, counts


def redact_pair(pair: dict[str, Any]) -> tuple[dict[str, Any], Counter]:
    out = copy.deepcopy(pair)
    counts: Counter = Counter()
    for field in ("input", "output"):
        out[field], field_counts = redact_text(str(out.get(field, "")))
        counts.update(field_counts)
    meta = out.get("metadata", {}) or {}
    for key in ("customer_id", "artifact_paths", "source_path", "evidence"):
        if key in meta and meta[key]:
            meta[key], field_counts = redact_text(str(meta[key]))
            counts.update(field_counts)
    out["metadata"] = meta
    return out, counts


def redact_pairs(pairs: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    redacted = []
    aggregate: Counter = Counter()
    touched = 0
    for pair in pairs:
        clean, counts = redact_pair(pair)
        if counts:
            touched += 1
        aggregate.update(counts)
        redacted.append(clean)
    return redacted, {"pairs_redacted": touched, "replacements": dict(sorted(aggregate.items()))}


def has_do_not_train_tag(entry: dict[str, Any]) -> bool:
    tags = entry.get("tags", []) or []
    if isinstance(tags, str):
        tags = [item.strip() for item in tags.split(",") if item.strip()]
    normalized = {str(tag).strip().lower() for tag in tags}
    return bool(normalized & DO_NOT_TRAIN_TAGS)
