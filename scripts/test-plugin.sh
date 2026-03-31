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
    state.session_id = ""
    state.exchanges = []
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
        f"project_id: test",
        f"session_id: sess-test",
    ]
    for k, v in extra.items():
        if k != "platform" and v:
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
