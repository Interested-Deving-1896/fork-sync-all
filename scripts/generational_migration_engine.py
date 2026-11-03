#!/usr/bin/env python3
"""Configuration-driven, auditable planner for cross-generation migrations.

The planner classifies candidate changes and records provenance. It never edits
source repositories or applies semantic transformations.
"""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any

SCHEMA_VERSION = "1.0"
_REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")


def _non_empty(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def validate_config(data: Any) -> dict[str, Any]:
    """Validate a decoded registry and return it unchanged."""
    if not isinstance(data, dict):
        raise ValueError("configuration must be a JSON object")
    if data.get("schema_version") != SCHEMA_VERSION:
        raise ValueError(f"schema_version must be {SCHEMA_VERSION}")

    generations = data.get("generations")
    if not isinstance(generations, list) or len(generations) < 2:
        raise ValueError("at least two generations are required")

    ids: list[str] = []
    for generation in generations:
        if not isinstance(generation, dict):
            raise ValueError("each generation must be an object")
        generation_id = generation.get("id")
        if not _non_empty(generation_id):
            raise ValueError("generation ids must be non-empty strings")
        ids.append(generation_id)
        for field in ("repository", "branch"):
            if not _non_empty(generation.get(field)):
                raise ValueError(f"generation {generation_id} requires {field}")
        if not _REPOSITORY.fullmatch(generation["repository"]):
            raise ValueError(f"generation {generation_id} repository must be owner/name")
        if "upstream_repository" in generation:
            if not _REPOSITORY.fullmatch(str(generation["upstream_repository"])):
                raise ValueError(
                    f"generation {generation_id} upstream_repository must be owner/name"
                )
        for field in ("upstream_branch",):
            if field in generation and not _non_empty(generation[field]):
                raise ValueError(f"generation {generation_id} {field} must be non-empty")
        technology = generation.get("technology", [])
        if not isinstance(technology, list) or any(not _non_empty(item) for item in technology):
            raise ValueError(f"generation {generation_id} technology must be a list of strings")
        aliases = generation.get("historical_aliases", [])
        if not isinstance(aliases, list) or any(not _REPOSITORY.fullmatch(str(item)) for item in aliases):
            raise ValueError(f"generation {generation_id} historical_aliases must contain owner/name values")

    if len(ids) != len(set(ids)):
        raise ValueError("generation ids must be unique")

    migration = data.get("migration")
    if not isinstance(migration, dict):
        raise ValueError("migration must be an object")
    source = migration.get("source_generation")
    target = migration.get("target_generation")
    if source not in ids or target not in ids or source == target:
        raise ValueError("migration source/target must be distinct configured generations")

    directions = migration.get("directions", [])
    allowed_directions = {"legacy-to-modern", "modern-to-legacy"}
    if not isinstance(directions, list) or any(item not in allowed_directions for item in directions):
        raise ValueError("migration directions must be a list of supported direction identifiers")
    return data


def load_config(path: str | Path) -> dict[str, Any]:
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    return validate_config(data)


def classify_change(change: dict[str, Any]) -> str:
    """Return the safest initial migration mode for a declared change."""
    kind = str(change.get("kind", "unknown")).lower()
    if kind in {"docs", "documentation", "metadata"}:
        return "mechanical_candidate"
    if kind in {"bugfix", "security"} and change.get("mapping_verified") is True:
        return "assisted"
    return "manual"


def build_plan(config: dict[str, Any], changes: list[dict[str, Any]]) -> dict[str, Any]:
    config = validate_config(config)
    if not isinstance(changes, list):
        raise ValueError("changes must be a list")
    if any(not isinstance(change, dict) for change in changes):
        raise ValueError("each change record must be an object")

    generations = {generation["id"]: generation for generation in config["generations"]}
    migration = config["migration"]
    source_id = migration["source_generation"]
    target_id = migration["target_generation"]
    items = []
    for change in changes:
        mode = classify_change(change)
        mapping = change.get("mapping", [])
        if not isinstance(mapping, list):
            raise ValueError("change mapping must be a list")
        items.append({
            "change_id": change.get("id", "UNIDENTIFIED"),
            "kind": change.get("kind", "unknown"),
            "mode": mode,
            "source_commit": change.get("source_commit"),
            "mapping": mapping,
            "requires_human_review": mode != "mechanical_candidate",
            "status": "planned",
        })

    return {
        "engine": "Generational Migration Engine",
        "schema_version": SCHEMA_VERSION,
        "project": config.get("project", {}),
        "source_generation": source_id,
        "target_generation": target_id,
        "source_repository": generations[source_id]["repository"],
        "target_repository": generations[target_id]["repository"],
        "items": items,
        "safety": {
            "automatic_source_edits": False,
            "automatic_target_edits": False,
            "human_approval_required_for_semantic_changes": True,
            "verification_required_before_completion": True,
            "upstream_sync_performed": False,
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("config")
    parser.add_argument("--changes", help="JSON file containing an array of change records")
    parser.add_argument("--output", help="Write plan to this file (stdout by default)")
    args = parser.parse_args()
    config = load_config(args.config)
    changes = json.loads(Path(args.changes).read_text(encoding="utf-8")) if args.changes else []
    if not isinstance(changes, list):
        raise ValueError("--changes must contain a JSON array")
    plan = build_plan(config, changes)
    rendered = json.dumps(plan, indent=2) + "\n"
    if args.output:
        Path(args.output).write_text(rendered, encoding="utf-8")
    else:
        print(rendered, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
