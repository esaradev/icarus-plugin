import json
from concurrent.futures import ThreadPoolExecutor

from storage import append_jsonl, atomic_write_json, atomic_write_text


def test_atomic_write_text(tmp_path):
    path = tmp_path / "entry.md"
    atomic_write_text(path, "one")
    atomic_write_text(path, "two")
    assert path.read_text("utf-8") == "two"


def test_atomic_write_json(tmp_path):
    path = tmp_path / "registry.json"
    atomic_write_json(path, {"models": [{"id": "m1"}]})
    assert json.loads(path.read_text("utf-8"))["models"][0]["id"] == "m1"


def test_append_jsonl_is_locked(tmp_path):
    path = tmp_path / "events.jsonl"

    def write(i):
        append_jsonl(path, {"i": i})

    with ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(write, range(50)))

    rows = [json.loads(line) for line in path.read_text("utf-8").splitlines()]
    assert sorted(row["i"] for row in rows) == list(range(50))
