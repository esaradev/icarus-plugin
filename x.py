"""X (Twitter) memory capture for Icarus.

Two layers:
- inbox: mechanical stub per post_id, no synthesis, pure provenance.
- note: Hermes-curated synthesis that flows through the existing
  wiki_ingest pipeline so it lands in the user's Obsidian vault with
  wikilinked handles + topics.

X ToS note: stored markdown holds post_ids, URLs, the user's own
takeaway, and short excerpts only. Long-term archival of full post
bodies is not the goal here.
"""

from __future__ import annotations

import json
import logging
import re
from datetime import datetime, timezone
from pathlib import Path

from . import state, wiki

logger = logging.getLogger(__name__)

X_SOURCE_TOOL = "x_search"
EXCERPT_LIMIT = 280  # one post's worth, no more


def _x_raw_root(fabric_dir: Path) -> Path:
    return fabric_dir / "raw" / "x"


def pathlib_basename_noext(path_str: str) -> str:
    if not path_str:
        return ""
    return Path(path_str).stem


def _inbox_root(fabric_dir: Path) -> Path:
    return _x_raw_root(fabric_dir) / "inbox"


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _today() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


def _slug(text: str, limit: int = 40) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", (text or "").lower()).strip("-")
    return s[:limit].strip("-") or "untitled"


def _norm_handle(h: str) -> str:
    h = (h or "").strip().lstrip("@")
    return h or "unknown"


def _post_url(post_id: str, handle: str = "") -> str:
    pid = re.sub(r"[^0-9]", "", post_id or "")
    if handle and pid:
        return f"https://x.com/{_norm_handle(handle)}/status/{pid}"
    if pid:
        return f"https://x.com/i/web/status/{pid}"
    return ""


def _excerpt(text: str) -> str:
    t = (text or "").strip().replace("\r", "")
    if len(t) <= EXCERPT_LIMIT:
        return t
    return t[:EXCERPT_LIMIT].rstrip() + "…"


def _parse_posts(posts) -> list[dict]:
    """Accept a list of dicts or a JSON string. Normalize fields."""
    if isinstance(posts, str):
        try:
            posts = json.loads(posts)
        except json.JSONDecodeError as exc:
            raise ValueError(f"posts must be JSON: {exc}") from exc
    if not isinstance(posts, list) or not posts:
        raise ValueError("posts must be a non-empty list")
    out = []
    for p in posts:
        if not isinstance(p, dict):
            raise ValueError("each post must be an object")
        post_id = str(p.get("post_id") or p.get("id") or "").strip()
        handle = _norm_handle(p.get("handle") or p.get("user") or "")
        text = (p.get("text") or "").strip()
        url = (p.get("url") or "").strip() or _post_url(post_id, handle)
        if not text and not post_id:
            continue
        out.append({"post_id": post_id, "handle": handle, "text": text, "url": url})
    if not out:
        raise ValueError("no usable posts")
    return out


def _parse_topics(topics) -> list[str]:
    if not topics:
        return []
    if isinstance(topics, list):
        items = topics
    else:
        items = [t for t in re.split(r"[,\n]", str(topics)) if t.strip()]
    return [t.strip() for t in items if t and t.strip()]


# ── Inbox (mechanical) ────────────────────────────────────────────

def inbox_write(post_id: str, handle: str, text: str, query: str = "",
                source_url: str = "", observed_at: str = "") -> dict:
    """Drop a raw stub for a single x_search hit. No wiki, no fabric entry."""
    post_id = (post_id or "").strip()
    if not post_id:
        return {"error": "post_id is required"}

    handle = _norm_handle(handle)
    observed_at = observed_at or _now_iso()
    source_url = source_url or _post_url(post_id, handle)

    inbox = _inbox_root(state.FABRIC_DIR)
    inbox.mkdir(parents=True, exist_ok=True)
    path = inbox / f"{_slug(post_id)}.md"

    body = (
        "---\n"
        f"type: x-inbox\n"
        f"source_tool: {X_SOURCE_TOOL}\n"
        f"post_id: {post_id}\n"
        f"user_handle: {handle}\n"
        f"source_url: {source_url}\n"
        f"observed_at: {observed_at}\n"
        f"query: {json.dumps(query or '')}\n"
        "---\n\n"
        f"> {_excerpt(text)}\n\n"
        f"— @{handle}, [{source_url}]({source_url})\n"
    )
    path.write_text(body, "utf-8")
    return {"status": "inboxed", "path": str(path)}


# ── Note (curated, wiki-ingested, Obsidian-visible) ───────────────

def _render_note(takeaway: str, posts: list[dict], topics: list[str],
                 query: str, observed_at: str) -> tuple[str, str]:
    """Return (title, markdown_body) for the raw source file.

    Section labels are bolded paragraphs, not markdown headings, so the
    wiki extractor doesn't create junk topic pages for 'Takeaway',
    'Excerpts', etc. Only the H1 (takeaway summary) becomes a heading,
    which the extractor treats as the source's primary topic.
    """
    title = takeaway.strip().splitlines()[0][:80]
    handles = sorted({p["handle"] for p in posts if p.get("handle") and p["handle"] != "unknown"})

    fm_lines = [
        "---",
        "type: x-thread-note",
        f"source_tool: {X_SOURCE_TOOL}",
        f"observed_at: {observed_at}",
        f"query: {json.dumps(query or '')}",
        f"post_ids: [{', '.join(p['post_id'] for p in posts if p['post_id'])}]",
        f"handles: [{', '.join('@' + h for h in handles)}]",
        "---",
    ]

    parts = ["\n".join(fm_lines), f"# {title}", "**Takeaway.** " + takeaway.strip()]

    excerpt_lines = ["**Excerpts.**"]
    for p in posts:
        quote = _excerpt(p["text"]) if p["text"] else "(no text captured)"
        attrib = f"— [[@{p['handle']}]]" if p["handle"] != "unknown" else "—"
        if p["url"]:
            attrib += f", [{p['url']}]({p['url']})"
        excerpt_lines.append(f"> {quote}\n>\n> {attrib}\n")
    parts.append("\n".join(excerpt_lines))

    if handles:
        parts.append("**Handles.** " + " ".join(f"[[@{h}]]" for h in handles))

    if topics:
        parts.append("**Topics.** " + " ".join(f"[[{t}]]" for t in topics))

    return title, "\n\n".join(parts) + "\n"


def _reify_explicit_topics(fabric_dir: Path, topics: list[str], source_link: str) -> list[str]:
    """User-supplied topic tags should reliably become topic pages.

    The wiki extractor pulls candidates from text — bare wikilinks in the
    body don't trigger page creation. So we call _upsert_page directly
    for each explicit topic.
    """
    if not topics:
        return []
    wiki_root = fabric_dir / "wiki"
    if not wiki_root.exists():
        return []
    out: list[str] = []
    for raw in topics:
        title = raw.strip().lstrip("#").strip()
        if not title:
            continue
        slug = wiki._slugify(title)
        if not slug:
            continue
        page = wiki_root / "topics" / f"{slug}.md"
        try:
            wiki._upsert_page(
                page,
                "topic",
                title,
                f"Tagged topic from X note ({source_link}).",
                source_link=source_link,
                body_append=f"_Seen in {source_link}._",
                generated_block_key=f"source-ref:{source_link}",
            )
            out.append(str(page))
        except Exception as exc:
            logger.warning("icarus: x topic upsert failed for %s: %s", title, exc)
    return out


def note_write(takeaway: str, posts, query: str = "", topics=None,
               topic_hint: str = "") -> dict:
    """Curated capture: write a structured raw file and ingest to wiki.

    Args mirror what Hermes would derive from an x_search result.
    Also writes a fabric entry so the note shows up in fabric_recall
    and telemetry alongside other memory.
    """
    takeaway = (takeaway or "").strip()
    if not takeaway:
        return {"error": "takeaway is required"}

    try:
        post_list = _parse_posts(posts)
    except ValueError as exc:
        return {"error": str(exc)}

    topic_list = _parse_topics(topics)
    observed_at = _now_iso()

    fabric_dir = state.FABRIC_DIR
    fabric_dir.mkdir(parents=True, exist_ok=True)

    x_root = _x_raw_root(fabric_dir)
    x_root.mkdir(parents=True, exist_ok=True)

    slug_seed = topic_hint or takeaway
    slug = f"{_slug(slug_seed)}-{_today()}"
    raw_path = x_root / f"{slug}.md"

    title, body = _render_note(takeaway, post_list, topic_list, query, observed_at)
    raw_path.write_text(body, "utf-8")

    # Wiki ingest is opt-in (needs wiki_init). If not initialised, return
    # the raw path so the user can ingest later; do not fail the whole call.
    wiki_root = fabric_dir / "wiki"
    wiki_result: dict
    topic_pages: list[str] = []
    if wiki_root.exists():
        try:
            wiki_result = wiki.ingest(raw_path, fabric_dir)
            source_slug = pathlib_basename_noext(wiki_result.get("source_page", ""))
            source_link = f"[[sources/{source_slug}]]" if source_slug else ""
            topic_pages = _reify_explicit_topics(fabric_dir, topic_list, source_link)
        except Exception as exc:
            logger.warning("icarus: x wiki ingest failed: %s", exc)
            wiki_result = {"error": str(exc)}
    else:
        wiki_result = {"skipped": "wiki not initialized — run wiki_init"}

    # Fabric entry so the note participates in recall + telemetry.
    handles = sorted({p["handle"] for p in post_list if p["handle"] and p["handle"] != "unknown"})
    fabric_summary = title
    evidence_lines = [f"{p['url']}" for p in post_list if p.get("url")]
    fabric_body = (
        f"{takeaway}\n\n"
        f"From X via {X_SOURCE_TOOL} on {observed_at}.\n"
        + (f"Handles: {', '.join('@' + h for h in handles)}\n" if handles else "")
        + (f"Query: {query}\n" if query else "")
        + (f"Source: {raw_path}\n" if raw_path else "")
    )
    fabric_path = state.write_entry(
        entry_type="note",
        content=fabric_body,
        summary=fabric_summary,
        source_tool=X_SOURCE_TOOL,
        evidence="; ".join(evidence_lines)[:500],
        tags="x-thread",
    )

    return {
        "status": "noted",
        "raw_path": str(raw_path),
        "wiki": wiki_result,
        "fabric_path": fabric_path,
        "topic_pages": topic_pages,
        "post_ids": [p["post_id"] for p in post_list if p["post_id"]],
        "handles": [f"@{h}" for h in handles],
    }


# ── Recall filtered to X ──────────────────────────────────────────

def recall_x(query: str, max_results: int = 5) -> dict:
    """Recall, then keep only entries Hermes captured from x_search."""
    raw = state.recall(query, max_results=max(max_results * 4, 20))
    x_only = [e for e in raw if str(e.get("source_tool", "")) == X_SOURCE_TOOL]
    return {
        "query": query,
        "count": len(x_only[:max_results]),
        "entries": x_only[:max_results],
    }
