"""Schema and YAML serialization helpers for fabric markdown entries."""

from __future__ import annotations

import csv
import io
from dataclasses import dataclass, field
from typing import Any

import yaml

ENTRY_TYPES = {
    "task",
    "decision",
    "review",
    "resolution",
    "research",
    "code-session",
    "session",
    "note",
    "dialogue",
}
TIERS = {"hot", "warm", "cold"}
STATUSES = {"", "open", "completed", "blocked", "superseded"}
TRAINING_VALUES = {"", "high", "normal", "low"}
BOOL_STRINGS = {"", "true", "false"}


class FabricSchemaError(ValueError):
    """Raised when a fabric entry cannot be represented safely."""


def _split_csv(value: str) -> list[str]:
    if not value:
        return []
    reader = csv.reader(io.StringIO(value), skipinitialspace=True)
    return [item.strip() for item in next(reader, []) if item.strip()]


def as_list(value: Any) -> list[str]:
    if value is None or value == "":
        return []
    if isinstance(value, list | tuple | set):
        return [str(item).strip() for item in value if str(item).strip()]
    if isinstance(value, str):
        return _split_csv(value)
    return [str(value).strip()]


def _clean_scalar(value: Any) -> str:
    return "" if value is None else str(value).strip()


@dataclass
class FabricEntry:
    id: str
    agent: str
    platform: str
    timestamp: str
    type: str
    tier: str
    summary: str
    project_id: str
    session_id: str
    content: str
    tags: list[str] = field(default_factory=list)
    status: str = ""
    outcome: str = ""
    review_of: str = ""
    revises: str = ""
    customer_id: str = ""
    assigned_to: str = ""
    training_value: str = ""
    verified: str = ""
    evidence: str = ""
    source_tool: str = ""
    artifact_paths: list[str] = field(default_factory=list)

    def validate(self) -> None:
        if not self.id:
            raise FabricSchemaError("id is required")
        if not self.agent:
            raise FabricSchemaError("agent is required")
        if not self.type:
            raise FabricSchemaError("type is required")
        if self.type not in ENTRY_TYPES:
            raise FabricSchemaError(f"unsupported type: {self.type}")
        if self.tier not in TIERS:
            raise FabricSchemaError(f"tier must be one of {sorted(TIERS)}")
        if not self.summary:
            raise FabricSchemaError("summary is required")
        if not self.content:
            raise FabricSchemaError("content is required")
        if self.status not in STATUSES:
            raise FabricSchemaError(f"unsupported status: {self.status}")
        if self.status == "open" and not self.assigned_to:
            raise FabricSchemaError("status='open' requires assigned_to")
        if self.type == "review" and not self.review_of:
            raise FabricSchemaError("type='review' requires review_of")
        for field_name in ("review_of", "revises"):
            value = getattr(self, field_name)
            if value and ":" not in value:
                raise FabricSchemaError(f"{field_name} must be agent:id")
        if self.training_value not in TRAINING_VALUES:
            raise FabricSchemaError("training_value must be high, normal, or low")
        if self.verified.lower() not in BOOL_STRINGS:
            raise FabricSchemaError("verified must be true or false")

    def frontmatter(self) -> dict[str, Any]:
        self.validate()
        data: dict[str, Any] = {
            "id": self.id,
            "agent": self.agent,
            "platform": self.platform,
            "timestamp": self.timestamp,
            "type": self.type,
            "tier": self.tier,
            "summary": self.summary,
            "project_id": self.project_id,
            "session_id": self.session_id,
        }
        optional_scalars = (
            "status",
            "outcome",
            "review_of",
            "revises",
            "customer_id",
            "assigned_to",
            "training_value",
            "verified",
            "evidence",
            "source_tool",
        )
        for key in optional_scalars:
            value = getattr(self, key)
            if value:
                data[key] = value
        if self.tags:
            data["tags"] = self.tags
        if self.artifact_paths:
            data["artifact_paths"] = self.artifact_paths
        return data

    def to_markdown(self) -> str:
        frontmatter = yaml.safe_dump(
            self.frontmatter(),
            allow_unicode=True,
            default_flow_style=False,
            sort_keys=False,
        ).strip()
        return f"---\n{frontmatter}\n---\n\n{self.content.rstrip()}\n"


def validate_fabric_entry(**kwargs) -> FabricEntry:
    entry = FabricEntry(
        tags=as_list(kwargs.pop("tags", "")),
        artifact_paths=as_list(kwargs.pop("artifact_paths", "")),
        **{key: _clean_scalar(value) for key, value in kwargs.items()},
    )
    entry.validate()
    return entry


def build_entry_document(**kwargs) -> str:
    return validate_fabric_entry(**kwargs).to_markdown()
