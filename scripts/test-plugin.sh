#!/usr/bin/env bash
# test-plugin.sh -- fixture-driven tests for Icarus plugin core workflows
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/icarus-test-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  pass: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL: %s\n' "$1" >&2; }

# ── Bootstrap plugin loader ──────────────────────────────
FABRIC_DIR="$TMP/fabric"
HOME_DIR="$TMP/.hermes-test"
mkdir -p "$FABRIC_DIR" "$FABRIC_DIR/cold" "$HOME_DIR/plugins/icarus" "$HOME_DIR/memories"

# copy plugin + support files into the temp home
cp "$REPO_DIR"/*.py "$HOME_DIR/plugins/icarus/"
cp "$REPO_DIR"/plugin.yaml "$HOME_DIR/plugins/icarus/"
[ -d "$REPO_DIR/scripts" ] && cp -R "$REPO_DIR/scripts" "$HOME_DIR/plugins/icarus/"

export FABRIC_DIR HOME_DIR REPO_DIR

python3 - <<'PYTEST'
import json
import os
import re
import shutil
import sys
import types
import importlib.util
from datetime import datetime, timezone
from pathlib import Path

repo_dir = Path(os.environ["REPO_DIR"])
fabric_dir = Path(os.environ["FABRIC_DIR"])
home_dir = Path(os.environ["HOME_DIR"])

# ── Load plugin as package ────────────────────────────────
ns = types.ModuleType("hermes_plugins")
ns.__path__ = []
ns.__package__ = "hermes_plugins"
sys.modules["hermes_plugins"] = ns

spec = importlib.util.spec_from_file_location(
    "hermes_plugins.icarus", str(repo_dir / "__init__.py"),
    submodule_search_locations=[str(repo_dir)])
mod = importlib.util.module_from_spec(spec)
mod.__package__ = "hermes_plugins.icarus"
mod.__path__ = [str(repo_dir)]
sys.modules["hermes_plugins.icarus"] = mod
spec.loader.exec_module(mod)

hooks = mod.hooks
state = mod.state
tools = mod.tools

# ── Load exporter ─────────────────────────────────────────
os.environ["FABRIC_DIR"] = str(fabric_dir)
exp_spec = importlib.util.spec_from_file_location("export_training", str(repo_dir / "export-training.py"))
exp = importlib.util.module_from_spec(exp_spec)
exp_spec.loader.exec_module(exp)
exp.FABRIC_DIR = fabric_dir

PASS = 0
FAIL = 0

def ok(msg):
    global PASS
    PASS += 1
    print(f"  pass: {msg}")

def bad(msg):
    global FAIL
    FAIL += 1
    print(f"  FAIL: {msg}", file=sys.stderr)

def reset_agent(name):
    os.environ["HERMES_AGENT_NAME"] = name
    os.environ["HERMES_HOME"] = str(home_dir)
    state.AGENT_NAME = name
    state.HERMES_HOME = home_dir
    state.FABRIC_DIR = fabric_dir
    state._JOB_FILE = home_dir / ".icarus-training-job.txt"
    state._STATE_FILE = home_dir / ".icarus-state.json"
    state._REGISTRY_FILE = home_dir / ".icarus-models.json"
    state._TELEMETRY_FILE = home_dir / ".icarus-telemetry.jsonl"
    state.session_id = ""
    state.exchanges = []
    state._recall_log = []
    # clear retriever cache
    state._retriever = None

def clean_fabric():
    for f in fabric_dir.glob("*.md"):
        f.unlink()
    cold = fabric_dir / "cold"
    for f in cold.glob("*.md"):
        f.unlink()

def write_fixture(agent, etype, body, summary, **extra):
    """Write a fixture entry directly to fabric. Returns (path, id)."""
    import secrets
    from datetime import datetime, timezone
    now = datetime.now(timezone.utc)
    entry_id = secrets.token_hex(4)
    suffix = secrets.token_hex(2)
    ts_iso = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    ts = now.strftime("%Y-%m-%dT%H%MZ")
    filename = f"{agent}-{etype}-{ts}-{suffix}.md"
    lines = [
        "---",
        f"id: {entry_id}",
        f"agent: {agent}",
        f"platform: {extra.get('platform', 'cli')}",
        f"timestamp: {ts_iso}",
        f"type: {etype}",
        f"tier: hot",
        f"summary: {summary}",
        f"project_id: {extra.get('project_id', 'test')}",
        f"session_id: {extra.get('session_id', 'sess-test')}",
    ]
    for k, v in extra.items():
        if k not in ("platform", "project_id", "session_id") and v:
            lines.append(f"{k}: {v}")
    lines.extend(["---", "", body])
    path = fabric_dir / filename
    path.write_text("\n".join(lines), "utf-8")
    import time; time.sleep(0.05)  # ensure distinct mtimes
    return str(path), entry_id

def parse_id(path):
    for line in Path(path).read_text("utf-8").splitlines():
        if line.startswith("id: "):
            return line.split(": ", 1)[1].strip()
    return ""


# ══════════════════════════════════════════════════════════
print("\nreview_of / revises export chains")
print("")
# ══════════════════════════════════════════════════════════

clean_fabric()
reset_agent("icarus")

# fixture: original work
_, orig_id = write_fixture("icarus", "code-session",
    "Built sliding window rate limiter using Redis sorted sets.",
    "rate limiter implementation")

# fixture: review using review_of (no refs field)
_, review_id = write_fixture("daedalus", "review",
    "MUST FIX: race condition in zadd/zcard sequence under concurrent load.",
    "reviewed rate limiter: race condition",
    review_of=f"icarus:{orig_id}", platform="telegram")

# fixture: fix using revises (no refs field)
_, fix_id = write_fixture("icarus", "code-session",
    "Fixed race condition by wrapping zadd+zcard in MULTI/EXEC transaction.",
    "fixed rate limiter after review",
    revises=f"icarus:{orig_id}")

# export and check
exp.FABRIC_DIR = fabric_dir
os.environ["FABRIC_DIR"] = str(fabric_dir)
entries = exp.scan_all()
pairs, rev_count, xplat_count = exp.extract_pairs(entries)

rc_pairs = [p for p in pairs if p["metadata"].get("type") == "review-correction"]
if len(rc_pairs) >= 1:
    ok("review_of/revises chain produces review-correction pair")
else:
    bad(f"expected >= 1 review-correction pair, got {len(rc_pairs)}")

# verify the pair content is correct
if rc_pairs:
    p = rc_pairs[0]
    if "sliding window" in p["input"].lower() or "rate limiter" in p["input"].lower():
        ok("review-correction pair references original work")
    else:
        bad(f"pair input doesn't reference original: {p['input'][:80]}")
    if "multi/exec" in p["output"].lower() or "fixed" in p["output"].lower():
        ok("review-correction pair output is the fix")
    else:
        bad(f"pair output isn't the fix: {p['output'][:80]}")


# ══════════════════════════════════════════════════════════
print("\ncross-platform via review_of")
print("")
# ══════════════════════════════════════════════════════════

xp_pairs = [p for p in pairs if p["metadata"].get("type") == "cross-platform"]
# the review is on telegram, original is on cli -> should produce cross-platform pair
if any(p["metadata"].get("source_platform") == "cli" and p["metadata"].get("target_platform") == "telegram" for p in xp_pairs):
    ok("cross-platform pair extracted via review_of")
else:
    bad(f"expected cross-platform pair cli->telegram, got {[(p['metadata'].get('source_platform'), p['metadata'].get('target_platform')) for p in xp_pairs]}")


# ══════════════════════════════════════════════════════════
print("\nduplicate suppression")
print("")
# ══════════════════════════════════════════════════════════

clean_fabric()

# write entries with BOTH refs and review_of pointing to the same original
_, orig_id2 = write_fixture("alice", "code-session",
    "Implemented OAuth2 PKCE flow for mobile clients.",
    "oauth2 pkce implementation")

_, review_id2 = write_fixture("bob", "review",
    "SHOULD FIX: state parameter not validated on callback.",
    "reviewed oauth2: missing state validation",
    review_of=f"alice:{orig_id2}",
    refs=f"alice:{orig_id2}")

_, fix_id2 = write_fixture("alice", "code-session",
    "Added state parameter validation on OAuth callback endpoint.",
    "fixed oauth2 state validation",
    revises=f"alice:{orig_id2}",
    refs=f"bob:{review_id2}")

entries2 = exp.scan_all()
pairs2, rev2, _ = exp.extract_pairs(entries2)
rc2 = [p for p in pairs2 if p["metadata"].get("type") == "review-correction"]

if len(rc2) == 1:
    ok("duplicate review-correction pair suppressed (refs + review_of = 1 pair)")
else:
    bad(f"expected exactly 1 review-correction pair, got {len(rc2)}")

# also check basic pairs aren't duplicated
basic2 = [p for p in pairs2 if p["metadata"].get("type") == "basic"]
files_seen = set()
dup_found = False
for p in basic2:
    key = p["input"]
    if key in files_seen:
        dup_found = True
    files_seen.add(key)
if not dup_found:
    ok("no duplicate basic pairs")
else:
    bad("duplicate basic pairs found")


# ══════════════════════════════════════════════════════════
print("\ndecision capture thresholds")
print("")
# ══════════════════════════════════════════════════════════

clean_fabric()
reset_agent("testbot")

# count entries before
before = len(list(fabric_dir.glob("*.md")))

# short user message + long response with decision+outcome -> should NOT capture
hooks.post_llm_call(
    session_id="test",
    user_message="ok",
    assistant_response="We resolved the billing issue because the root cause was a payment gateway timeout that caused duplicate charges. The result: refund issued for $47.50 and idempotency key added to prevent recurrence. " * 2,
    platform="cli",
)
after_short = len(list(fabric_dir.glob("*.md")))
if after_short == before:
    ok("short user message (2 chars) does not trigger decision capture")
else:
    bad(f"short user message created {after_short - before} entries")

# long user message + short response -> should NOT capture
hooks.post_llm_call(
    session_id="test",
    user_message="fix the race condition in the rate limiter redis implementation that causes off-by-one errors under concurrent load",
    assistant_response="Done.",
    platform="cli",
)
after_short_resp = len(list(fabric_dir.glob("*.md")))
if after_short_resp == after_short:
    ok("short response (<200 chars) does not trigger decision capture")
else:
    bad(f"short response created {after_short_resp - after_short} entries")

# long user message + long response with decision+outcome -> SHOULD capture
hooks.post_llm_call(
    session_id="test",
    user_message="fix the race condition in the rate limiter redis implementation that causes off-by-one errors under concurrent load",
    assistant_response="We resolved the race condition because the root cause was non-atomic zadd/zcard operations. The result: wrapped both operations in a MULTI/EXEC transaction block. Under load testing with 1000 concurrent requests, the off-by-one error no longer reproduces. The fix maintains the same O(log N) complexity for the sliding window check. " * 2,
    platform="cli",
)
after_good = len(list(fabric_dir.glob("*.md")))
if after_good == after_short_resp + 1:
    ok("substantial user message + decision+outcome response triggers capture")
else:
    bad(f"expected 1 new entry, got {after_good - after_short_resp}")

# verify the captured entry has Task: ... Result: ... structure
if after_good > after_short_resp:
    latest = sorted(fabric_dir.glob("*.md"), key=lambda p: p.stat().st_mtime)[-1]
    content = latest.read_text("utf-8")
    if "Task:" in content and "Result:" in content:
        ok("captured decision includes Task and Result context")
    else:
        bad("captured decision missing Task/Result structure")
    if "training_value: high" in content:
        ok("captured decision tagged training_value: high")
    else:
        bad("captured decision missing training_value: high")

# long user message + response with decision but NO outcome -> should NOT capture
hooks.post_llm_call(
    session_id="test",
    user_message="fix the race condition in the rate limiter redis implementation that causes off-by-one errors under concurrent load",
    assistant_response="I've decided to fix this by using a Lua script for atomicity. This approach is cleaner and avoids the pipeline overhead. I'll implement it now and test with the existing load test suite. The implementation will take about 30 minutes. Let me start coding. " * 2,
    platform="cli",
)
after_no_outcome = len(list(fabric_dir.glob("*.md")))
if after_no_outcome == after_good:
    ok("decision keyword without outcome indicator does not trigger capture")
else:
    bad(f"decision without outcome created {after_no_outcome - after_good} entries")


# ══════════════════════════════════════════════════════════
print("\nmodel switch + rollback")
print("")
# ══════════════════════════════════════════════════════════

clean_fabric()
reset_agent("testbot")

# create a fake .env
env_file = home_dir / ".env"
env_file.write_text("ANTHROPIC_API_KEY=sk-ant-fake\nLLM_MODEL=claude-sonnet-4\nHERMES_AGENT_NAME=testbot\nTOGETHER_API_KEY=tok-fake-test\n", "utf-8")

# create a fake model in the registry
registry = {"models": [{
    "job_id": "ft-test-001",
    "base_model": "Qwen/Qwen2-7B-Instruct",
    "output_model": "user/testbot-v1",
    "suffix": "testbot-v1",
    "created": "2026-03-31T00:00:00Z",
    "pair_count": 50,
    "status": "completed",
    "eval_scores": {"task_completion": 0.8, "format_compliance": 0.9, "style_match": 0.7},
    "active": False,
}], "active_model": None}
state._REGISTRY_FILE.write_text(json.dumps(registry), "utf-8")

# switch to the replacement model
result = json.loads(tools.fabric_switch_model({"model_id": "user/testbot-v1"}))
if result.get("status") == "switched":
    ok("model switch succeeds with passing eval scores")
else:
    bad(f"model switch failed: {result}")

# verify .env was updated
env_content = env_file.read_text("utf-8")
if "LLM_MODEL=user/testbot-v1" in env_content:
    ok("LLM_MODEL updated in .env")
else:
    bad(f"LLM_MODEL not updated: {env_content[:200]}")

# verify ANTHROPIC_API_KEY was preserved
if "ANTHROPIC_API_KEY=sk-ant-fake" in env_content:
    ok("ANTHROPIC_API_KEY preserved during switch")
else:
    bad("ANTHROPIC_API_KEY was clobbered")

# verify backup exists
backup = home_dir / ".env.backup"
if backup.exists():
    ok(".env.backup created")
else:
    bad(".env.backup missing")

# verify backup has the old model
backup_content = backup.read_text("utf-8")
if "LLM_MODEL=claude-sonnet-4" in backup_content:
    ok("backup contains original model")
else:
    bad(f"backup doesn't contain original: {backup_content[:200]}")

# verify registry updated
reg = json.loads(state._REGISTRY_FILE.read_text("utf-8"))
active = [m for m in reg["models"] if m.get("active")]
if len(active) == 1 and active[0]["output_model"] == "user/testbot-v1":
    ok("registry marks new model as active")
else:
    bad(f"registry active state wrong: {active}")

# rollback
result = json.loads(tools.fabric_rollback_model({}))
if result.get("status") == "rolled_back":
    ok("rollback succeeds")
else:
    bad(f"rollback failed: {result}")

# verify .env restored
env_after = env_file.read_text("utf-8")
if "LLM_MODEL=claude-sonnet-4" in env_after:
    ok("rollback restored original LLM_MODEL")
else:
    bad(f"rollback didn't restore model: {env_after[:200]}")

if "ANTHROPIC_API_KEY=sk-ant-fake" in env_after:
    ok("rollback preserved ANTHROPIC_API_KEY")
else:
    bad("rollback clobbered ANTHROPIC_API_KEY")

# verify registry deactivated
reg2 = json.loads(state._REGISTRY_FILE.read_text("utf-8"))
active2 = [m for m in reg2["models"] if m.get("active")]
if len(active2) == 0:
    ok("rollback deactivates model in registry")
else:
    bad(f"rollback left active models: {active2}")

# switch with failing eval scores
registry3 = {"models": [{
    "job_id": "ft-test-002",
    "base_model": "Qwen/Qwen2-7B-Instruct",
    "output_model": "user/testbot-bad",
    "suffix": "testbot-bad",
    "created": "2026-03-31T00:00:00Z",
    "pair_count": 50,
    "status": "completed",
    "eval_scores": {"task_completion": 0.3, "format_compliance": 0.4, "style_match": 0.2},
    "active": False,
}], "active_model": None}
state._REGISTRY_FILE.write_text(json.dumps(registry3), "utf-8")

result = json.loads(tools.fabric_switch_model({"model_id": "user/testbot-bad"}))
if "error" in result and "below threshold" in result["error"]:
    ok("switch rejected when eval score below threshold")
else:
    bad(f"switch should have been rejected: {result}")

# switch with no eval scores
registry4 = {"models": [{
    "job_id": "ft-test-003",
    "output_model": "user/testbot-noeval",
    "status": "completed",
    "eval_scores": None,
    "active": False,
}], "active_model": None}
state._REGISTRY_FILE.write_text(json.dumps(registry4), "utf-8")

result = json.loads(tools.fabric_switch_model({"model_id": "user/testbot-noeval"}))
if "error" in result and "eval" in result["error"].lower():
    ok("switch rejected when no eval scores exist")
else:
    bad(f"switch should require eval: {result}")

# rollback with no backup
backup.unlink(missing_ok=True)
result = json.loads(tools.fabric_rollback_model({}))
if "error" in result and "backup" in result["error"].lower():
    ok("rollback fails gracefully when no backup exists")
else:
    bad(f"rollback should fail without backup: {result}")


# ══════════════════════════════════════════════════════════
print("\nend-to-end: write -> export -> inspect JSONL")
print("")
# ══════════════════════════════════════════════════════════

clean_fabric()
reset_agent("alice")

# write a linked chain using the actual plugin tools
r1 = json.loads(tools.fabric_write({
    "type": "code-session",
    "content": "Implemented JWT refresh token rotation with 7-day expiry.",
    "summary": "jwt refresh rotation",
    "status": "open",
    "assigned_to": "bob",
    "training_value": "high",
    "verified": "true",
    "evidence": "tests pass, 12/12 auth tests green",
    "source_tool": "code_editor",
    "artifact_paths": "src/auth.ts, tests/auth.test.ts",
}))
assert r1.get("status") == "written", f"e2e write 1 failed: {r1}"
orig_id = parse_id(r1["path"])

reset_agent("bob")
r2 = json.loads(tools.fabric_write({
    "type": "review",
    "content": "MUST FIX: refresh tokens stored in plain text. Hash with bcrypt before storing.",
    "summary": "reviewed jwt: plaintext token storage",
    "review_of": f"alice:{orig_id}",
    "status": "completed",
    "outcome": "MUST FIX plaintext storage",
}))
assert r2.get("status") == "written", f"e2e write 2 failed: {r2}"

reset_agent("alice")
r3 = json.loads(tools.fabric_write({
    "type": "code-session",
    "content": "Added bcrypt hashing for refresh tokens before database storage.",
    "summary": "fixed jwt: bcrypt token hashing",
    "revises": f"alice:{orig_id}",
    "status": "completed",
    "verified": "true",
    "evidence": "tests pass after adding bcrypt",
}))
assert r3.get("status") == "written", f"e2e write 3 failed: {r3}"

# export with subprocess (the real CLI path)
import subprocess, tempfile
with tempfile.TemporaryDirectory() as export_dir:
    exp_result = subprocess.run(
        ["python3", str(repo_dir / "export-training.py"), "--output", export_dir,
         "--fabric-dir", str(fabric_dir), "--mode", "high-precision"],
        capture_output=True, text=True, timeout=30,
    )
    assert exp_result.returncode == 0, f"export failed: {exp_result.stderr}"

    # inspect together.jsonl
    together_path = Path(export_dir) / "together.jsonl"
    assert together_path.exists(), "together.jsonl not produced"
    lines = [json.loads(l) for l in together_path.read_text().strip().split("\n") if l.strip()]

    ok(f"e2e export produced {len(lines)} JSONL lines")

    # verify structure: system + user + assistant
    for i, line in enumerate(lines):
        msgs = line.get("messages", [])
        assert len(msgs) >= 3, f"line {i}: expected 3+ messages, got {len(msgs)}"
        assert msgs[0]["role"] == "system", f"line {i}: first role should be system"
        assert msgs[-1]["role"] == "assistant", f"line {i}: last role should be assistant"
    ok("all JSONL lines have system+user+assistant structure")

    # verify review-correction pair exists
    rc_found = any("self-correct" in l["messages"][1]["content"].lower() for l in lines)
    if rc_found:
        ok("e2e JSONL contains review-correction pair")
    else:
        bad("e2e JSONL missing review-correction pair")

    # verify verified entry appears in high-precision mode
    verified_ref = any("jwt" in l["messages"][1]["content"].lower() for l in lines)
    if verified_ref:
        ok("verified entry included in high-precision export")
    else:
        bad("verified entry missing from high-precision export")


# ══════════════════════════════════════════════════════════
print("\nretrieval quality: ranking, not just presence")
print("")
# ══════════════════════════════════════════════════════════

clean_fabric()
reset_agent("alice")

# create entries with varying relevance to "rate limiter redis"
write_fixture("alice", "code-session",
    "Built sliding window rate limiter using Redis sorted sets with per-route config.",
    "rate limiter implementation with redis sorted sets",
    tags="rate-limiter, redis", training_value="high", verified="true")

write_fixture("alice", "research",
    "Researched PostgreSQL partial indexes for query optimization on the billing module.",
    "postgres partial index research for billing",
    tags="postgres, billing")

write_fixture("bob", "review",
    "Reviewed the rate limiter. Found race condition in zadd/zcard under concurrent load.",
    "reviewed rate limiter: race condition in redis operations",
    tags="rate-limiter, review")

write_fixture("alice", "code-session",
    "Built WebSocket pub/sub broker in Node for real-time notifications.",
    "websocket pub/sub broker for notifications",
    tags="websocket, node")

write_fixture("alice", "session",
    "Discussed project timeline and sprint planning for Q2.",
    "sprint planning discussion Q2")

# load retriever
ret_spec = importlib.util.spec_from_file_location("fabric_ret", str(repo_dir / "fabric-retrieve.py"))
ret = importlib.util.module_from_spec(ret_spec)
ret.FABRIC_DIR = fabric_dir
ret_spec.loader.exec_module(ret)

# query: "rate limiter redis" -- should rank rate limiter entries above postgres/websocket/sprint
results = ret.retrieve("rate limiter redis", max_results=5)
if not results:
    bad("retrieval returned no results for 'rate limiter redis'")
else:
    top = results[0][1]
    top_summary = top.get("summary", "").lower()
    if "rate limiter" in top_summary and "redis" in top_summary:
        ok("top-1 for 'rate limiter redis' is the implementation entry")
    else:
        bad(f"top-1 wrong: {top_summary}")

    # verify postgres and sprint are ranked below rate limiter entries
    rate_limiter_indices = []
    other_indices = []
    for i, (score, e) in enumerate(results):
        s = e.get("summary", "").lower()
        if "rate limiter" in s or "redis" in s:
            rate_limiter_indices.append(i)
        elif "postgres" in s or "sprint" in s or "websocket" in s:
            other_indices.append(i)

    if rate_limiter_indices and other_indices:
        if max(rate_limiter_indices) < min(other_indices):
            ok("all rate limiter entries rank above unrelated entries")
        else:
            bad(f"ranking wrong: rate_limiter at {rate_limiter_indices}, others at {other_indices}")
    elif rate_limiter_indices:
        ok("only rate limiter entries returned (unrelated filtered out)")
    else:
        bad("no rate limiter entries in results")

# query: "billing postgres" -- should rank postgres above rate limiter
results2 = ret.retrieve("billing postgres", max_results=5)
if results2:
    top2 = results2[0][1]
    if "postgres" in top2.get("summary", "").lower() or "billing" in top2.get("summary", "").lower():
        ok("top-1 for 'billing postgres' is the postgres entry")
    else:
        bad(f"top-1 for billing query wrong: {top2.get('summary','')}")
else:
    bad("no results for 'billing postgres'")

# query: "websocket notifications" -- should rank websocket above everything
results3 = ret.retrieve("websocket notifications", max_results=5)
if results3:
    top3 = results3[0][1]
    if "websocket" in top3.get("summary", "").lower():
        ok("top-1 for 'websocket notifications' is the websocket entry")
    else:
        bad(f"top-1 for websocket query wrong: {top3.get('summary','')}")
else:
    bad("no results for 'websocket notifications'")

# ambiguous query: "fix" -- should prefer review (which mentions fix) or code-session
results4 = ret.retrieve("fix race condition", max_results=3)
if results4:
    top4_type = results4[0][1].get("type", "")
    if top4_type in ("code-session", "review"):
        ok(f"ambiguous 'fix race condition' returns {top4_type} (not session/research)")
    else:
        bad(f"ambiguous query returned {top4_type}")
else:
    bad("no results for 'fix race condition'")


# ══════════════════════════════════════════════════════════
print("\nevidence-backed fields")
print("")
# ══════════════════════════════════════════════════════════

clean_fabric()
reset_agent("alice")

# write entry with evidence fields
r = json.loads(tools.fabric_write({
    "type": "code-session",
    "content": "Implemented rate limiter with Redis backend.",
    "summary": "rate limiter with evidence",
    "verified": "true",
    "evidence": "12/12 tests pass, load test 1000 rps stable",
    "source_tool": "bash",
    "artifact_paths": "src/limiter.ts, tests/limiter.test.ts",
    "training_value": "high",
}))
assert r.get("status") == "written", f"evidence write failed: {r}"

# read the entry and verify fields are on disk
content = Path(r["path"]).read_text("utf-8")
if "verified: true" in content:
    ok("verified field written to entry")
else:
    bad("verified field missing from entry")

if "evidence: 12/12 tests pass" in content:
    ok("evidence field written to entry")
else:
    bad("evidence field missing from entry")

if "source_tool: bash" in content:
    ok("source_tool field written to entry")
else:
    bad("source_tool field missing from entry")

if "artifact_paths:" in content and "src/limiter.ts" in content:
    ok("artifact_paths field written to entry")
else:
    bad("artifact_paths field missing from entry")

# write an unverified entry
r2 = json.loads(tools.fabric_write({
    "type": "session",
    "content": "Had a conversation about architecture options.",
    "summary": "architecture discussion",
    "training_value": "low",
}))
assert r2.get("status") == "written"

# export in high-precision mode -- verified entry should appear, unverified session should not
exp.FABRIC_DIR = fabric_dir
all_e = exp.scan_all()
hp_entries = [e for e in all_e
              if e.get("training_value") == "high"
              or e.get("status") == "completed"
              or (e.get("type") == "review" and e.get("review_of"))
              or str(e.get("verified", "")).lower() == "true"]
excluded_entries = [e for e in all_e if e not in hp_entries]

if any("rate limiter" in str(e.get("summary", "")).lower() for e in hp_entries):
    ok("verified entry passes high-precision filter")
else:
    bad("verified entry excluded from high-precision")

if any("architecture" in str(e.get("summary", "")).lower() for e in excluded_entries):
    ok("low-value unverified session excluded from high-precision")
else:
    bad("low-value session not excluded from high-precision")


# ══════════════════════════════════════════════════════════
print("\nsession scoring + corpus report")
print("")
# ══════════════════════════════════════════════════════════

clean_fabric()
reset_agent("alice")

# unrelated telemetry from another session/agent should not affect current score
state._TELEMETRY_FILE.write_text("\n".join([
    json.dumps({
        "event": "recall", "result_ids": ["old1"], "session_id": "old-session", "agent": "bob"
    }),
    json.dumps({
        "event": "usage", "entry_id": "old1", "session_id": "old-session", "agent": "bob"
    }),
]), "utf-8")

state.session_id = "sess-live"
state.exchanges = [{
    "user": "Investigate and fix the auth race condition in the Redis-backed limiter under concurrent load.",
    "assistant": (
        "We resolved the auth race because the root cause was a non-atomic update path in Redis. "
        "The result: moved the critical section into a Lua script and validated it with the concurrency test suite."
    ),
}]
scores = state.score_session()
if scores.get("recall_usage") == 0.0:
    ok("session scoring ignores telemetry from other sessions and agents")
else:
    bad(f"session scoring leaked unrelated telemetry: recall_usage={scores.get('recall_usage')}")

# unlinked session entries should not count as linked workflow entries
write_fixture("alice", "task", "Investigate auth bug.", "auth bug task", session_id="sess-live")
write_fixture("alice", "code-session", "Implemented the auth fix.", "auth fix", session_id="sess-live")
write_fixture("alice", "decision", "Decided to ship the auth fix.", "auth ship decision", session_id="sess-live")
scores2 = state.score_session()
if scores2.get("linked_entries") == 0.0:
    ok("session scoring does not treat unlinked note volume as linked workflow activity")
else:
    bad(f"unlinked entries inflated linked_entries score: {scores2.get('linked_entries')}")

clean_fabric()
reset_agent("alice")
state.session_id = "sess-linked"
state.exchanges = [{
    "user": "Fix and review the rate limiter race under load with a full correction loop.",
    "assistant": (
        "We resolved the rate limiter race because the root cause was a non-atomic Redis sequence. "
        "The result: reviewer feedback was incorporated and the fix passed load testing."
    ),
}]
_, base_id = write_fixture("alice", "code-session", "Built initial limiter.", "initial limiter", session_id="sess-linked")
write_fixture("bob", "review", "Need atomic update path.", "reviewed limiter", review_of=f"alice:{base_id}", session_id="sess-linked")
write_fixture("alice", "code-session", "Added atomic Lua script.", "revised limiter", revises=f"alice:{base_id}", session_id="sess-linked")
scores3 = state.score_session()
if scores3.get("linked_entries") == 1.0:
    ok("session scoring gives full linked_entries credit to a real review/revise chain")
else:
    bad(f"linked review/revise chain scored incorrectly: {scores3.get('linked_entries')}")

clean_fabric()
reset_agent("alice")
write_fixture("alice", "task", "High and verified.", "high verified", training_value="high", verified="true")
write_fixture("alice", "task", "Verified only.", "verified only", verified="true")
write_fixture("alice", "task", "High only.", "high only", training_value="high")
write_fixture("alice", "task", "Neither.", "neither")
report = state.build_weekly_report()
if report.get("trainable_estimate") == 3:
    ok("corpus report trainable_estimate counts the union of high and verified entries")
else:
    bad(f"trainable_estimate double-counted overlap: {report.get('trainable_estimate')}")


# ══════════════════════════════════════════════════════════
print("\nobsidian integration")
print("")
# ══════════════════════════════════════════════════════════

clean_fabric()
reset_agent("alice")

# write an entry that will be the review target
_, target_id = write_fixture("alice", "code-session",
    "Built OAuth PKCE flow.",
    "oauth pkce implementation")
target_filename = None
for f in fabric_dir.glob("*.md"):
    head = f.read_text("utf-8")[:400]
    if f"id: {target_id}" in head:
        target_filename = f.stem
        break

# enable obsidian mode
os.environ["ICARUS_OBSIDIAN"] = "1"

# write a review with review_of -- should get wikilinks
reset_agent("bob")
r = json.loads(tools.fabric_write({
    "type": "review",
    "content": "MUST FIX: missing state param validation.",
    "summary": "reviewed oauth pkce",
    "review_of": f"alice:{target_id}",
}))
assert r.get("status") == "written", f"obsidian write failed: {r}"

review_content = Path(r["path"]).read_text("utf-8")

# verify frontmatter is unchanged
if review_content.startswith("---") and "id: " in review_content[:400]:
    ok("obsidian: frontmatter preserved")
else:
    bad("obsidian: frontmatter corrupted")

# verify wikilinks section exists
if "## Links" in review_content:
    ok("obsidian: ## Links section added")
else:
    bad("obsidian: ## Links section missing")

# verify wikilink resolves to correct file
if target_filename and f"[[{target_filename}]]" in review_content:
    ok(f"obsidian: wikilink resolves to [[{target_filename}]]")
else:
    bad(f"obsidian: wikilink not found (expected [[{target_filename}]])")

# verify daily note created
today = datetime.now().strftime("%Y-%m-%d")
daily_path = fabric_dir / "daily" / f"{today}.md"
if daily_path.exists():
    ok("obsidian: daily note created")
    daily_content = daily_path.read_text("utf-8")
    review_stem = Path(r["path"]).stem
    if f"[[{review_stem}]]" in daily_content:
        ok("obsidian: daily note links to new entry")
    else:
        bad("obsidian: daily note missing entry link")
else:
    bad("obsidian: daily note not created")

# test init_obsidian
import importlib.util as _importlib_util
_obsidian_path = repo_dir / "obsidian.py"
_obsidian_spec = _importlib_util.spec_from_file_location("icarus_obsidian", _obsidian_path)
_obsidian_mod = _importlib_util.module_from_spec(_obsidian_spec)
assert _obsidian_spec and _obsidian_spec.loader, "failed to load obsidian.py"
_obsidian_spec.loader.exec_module(_obsidian_mod)
_init_obs = _obsidian_mod.init_obsidian
vault_dir = home_dir / "vault-root"
os.environ["OBSIDIAN_VAULT_PATH"] = str(vault_dir)
init_result = _init_obs(fabric_dir)
if init_result.get("status") in ("initialized", "already_initialized"):
    ok("obsidian: init_obsidian runs successfully")
else:
    bad(f"obsidian: init_obsidian failed: {init_result}")

if init_result.get("vault_dir") == str(vault_dir):
    ok("obsidian: init_obsidian uses OBSIDIAN_VAULT_PATH as vault root")
else:
    bad(f"obsidian: wrong vault_dir returned: {init_result.get('vault_dir')}")

obs_app = vault_dir / ".obsidian" / "app.json"
if obs_app.exists():
    ok("obsidian: .obsidian/app.json created at vault root")
else:
    bad("obsidian: .obsidian/app.json missing at vault root")

del os.environ["OBSIDIAN_VAULT_PATH"]

# disable obsidian and verify no links added
del os.environ["ICARUS_OBSIDIAN"]
clean_fabric()
reset_agent("alice")

r2 = json.loads(tools.fabric_write({
    "type": "task",
    "content": "Plain task without obsidian.",
    "summary": "plain task",
}))
assert r2.get("status") == "written"
plain_content = Path(r2["path"]).read_text("utf-8")
if "## Links" not in plain_content:
    ok("obsidian: disabled mode produces no wikilinks")
else:
    bad("obsidian: wikilinks added even when ICARUS_OBSIDIAN is unset")

daily_dir = fabric_dir / "daily"
# daily dir might exist from previous test but should have no new note for this entry
if not daily_dir.exists() or not any(
    Path(r2["path"]).stem in f.read_text("utf-8")
    for f in daily_dir.glob("*.md")
):
    ok("obsidian: disabled mode produces no daily note entry")
else:
    bad("obsidian: daily note updated even when ICARUS_OBSIDIAN is unset")

# verify export still works on obsidian-formatted entries
os.environ["ICARUS_OBSIDIAN"] = "1"
clean_fabric()
reset_agent("alice")
write_fixture("alice", "code-session", "Built rate limiter.", "rate limiter")
r3 = json.loads(tools.fabric_write({
    "type": "task",
    "content": "Another task with obsidian links in body.",
    "summary": "obsidian body task",
}))
del os.environ["ICARUS_OBSIDIAN"]

# export should still parse the entry correctly
exp.FABRIC_DIR = fabric_dir
obs_entries = exp.scan_all()
obs_parsed = [e for e in obs_entries if "obsidian body task" in str(e.get("summary", ""))]
if obs_parsed:
    ok("obsidian: export parses obsidian-formatted entries")
else:
    bad("obsidian: export fails on obsidian-formatted entries")


# ══════════════════════════════════════════════════════════
print(f"\n{'─' * 40}")
print(f"  {PASS} passed, {FAIL} failed")
if FAIL > 0:
    sys.exit(1)
print("  all tests pass")
PYTEST

[ $? -eq 0 ] && pass "plugin test suite" || fail "plugin test suite"

echo ""
echo "────────────────────────"
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "  all tests pass" || echo "  FAILURES"
exit "$FAIL"
