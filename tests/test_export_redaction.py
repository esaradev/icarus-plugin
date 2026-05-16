import json
import os
import subprocess
import sys
from pathlib import Path

from redaction import has_do_not_train_tag, redact_pair


def test_redacts_common_sensitive_values():
    pair = {
        "input": "Use sk-abcdefghijklmnopqrstuvwxyz and email user@example.com",
        "output": "customer cus_123456789 lives at /Users/me/project/secret.txt",
        "metadata": {"artifact_paths": "/tmp/build/out.txt"},
    }
    redacted, report = redact_pair(pair)

    blob = json.dumps(redacted)
    assert "sk-abcdefghijklmnopqrstuvwxyz" not in blob
    assert "user@example.com" not in blob
    assert "cus_123456789" not in blob
    assert report["openai_key"] == 1
    assert report["email"] == 1


def test_do_not_train_tags_are_detected():
    assert has_do_not_train_tag({"tags": ["ops", "do-not-train"]})
    assert has_do_not_train_tag({"tags": "ops, private"})
    assert not has_do_not_train_tag({"tags": ["ops"]})


def test_export_filters_and_writes_redaction_report(tmp_path):
    fabric = tmp_path / "fabric"
    out = tmp_path / "out"
    fabric.mkdir()
    (fabric / "keep.md").write_text(
        "---\n"
        "id: keep1234\n"
        "agent: icarus\n"
        "platform: cli\n"
        "timestamp: '2026-05-16T00:00:00Z'\n"
        "type: task\n"
        "tier: hot\n"
        "summary: Keep this\n"
        "training_value: high\n"
        "verified: 'true'\n"
        "tags:\n  - useful\n"
        "---\n\n"
        "The result mentions user@example.com and sk-abcdefghijklmnopqrstuvwxyz.\n",
        encoding="utf-8",
    )
    (fabric / "drop.md").write_text(
        "---\n"
        "id: drop1234\n"
        "agent: icarus\n"
        "platform: cli\n"
        "timestamp: '2026-05-16T00:00:00Z'\n"
        "type: task\n"
        "tier: hot\n"
        "summary: Drop this\n"
        "tags:\n  - do-not-train\n"
        "---\n\n"
        "This should not appear.\n",
        encoding="utf-8",
    )

    env = {**os.environ, "FABRIC_DIR": str(fabric)}
    result = subprocess.run(
        [sys.executable, "export-training.py", "--output", str(out), "--mode", "high-volume"],
        cwd=Path(__file__).resolve().parents[1],
        env=env,
        text=True,
        capture_output=True,
        check=True,
    )
    assert "do-not-train:      1 excluded" in result.stdout
    report = json.loads((out / "redaction-report.json").read_text("utf-8"))
    assert report["pairs_redacted"] >= 1
    raw = (out / "together.jsonl").read_text("utf-8")
    assert "user@example.com" not in raw
    assert "This should not appear" not in raw
