import pytest
import yaml

from fabric_schema import FabricSchemaError, build_entry_document, validate_fabric_entry


def base_kwargs(**overrides):
    data = {
        "id": "deadbeef",
        "agent": "icarus",
        "platform": "cli",
        "timestamp": "2026-05-16T00:00:00Z",
        "type": "task",
        "tier": "hot",
        "summary": "Fix YAML escaping",
        "project_id": "icarus-plugin",
        "session_id": "sess-1",
        "content": "Implemented safe frontmatter serialization.",
    }
    data.update(overrides)
    return data


def test_yaml_lists_are_serialized_safely():
    doc = build_entry_document(
        **base_kwargs(
            tags='alpha, "needs, quoting", bracket[value]',
            artifact_paths=["src/a,b.py", "tests/test file.py"],
        )
    )
    frontmatter = doc.split("---", 2)[1]
    data = yaml.safe_load(frontmatter)

    assert data["tags"] == ["alpha", "needs, quoting", "bracket[value]"]
    assert data["artifact_paths"] == ["src/a,b.py", "tests/test file.py"]


def test_open_status_requires_assignee():
    with pytest.raises(FabricSchemaError):
        validate_fabric_entry(**base_kwargs(status="open"))


def test_review_requires_review_of():
    with pytest.raises(FabricSchemaError):
        validate_fabric_entry(**base_kwargs(type="review"))


def test_training_value_is_validated():
    with pytest.raises(FabricSchemaError):
        validate_fabric_entry(**base_kwargs(training_value="great"))
