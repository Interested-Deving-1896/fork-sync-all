#!/usr/bin/env python3
"""Configuration-driven, auditable planning engine for cross-generation migrations.

This first implementation intentionally plans and classifies work; it does not
apply source changes automatically. Semantic transformations require review.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
from typing import Any

SCHEMA_VERSION = "1.0"

def load_config(path: str | Path) -> dict[str, Any]:
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    if data.get("schema_version") != SCHEMA_VERSION:
        raise ValueError(f"schema_version must be {SCHEMA_VERSION}")
    generations = data.get("generations")
    if not isinstance(generations, list) or len(generations) < 2:
        raise ValueError("at least two generations are required")
    ids = [g.get("id") for g in generations]
    if any(not isinstance(i, str) or not i.strip() for i in ids) or len(ids) != len(set(ids)):
        raise ValueError("generation ids must be unique, non-empty strings")
    for g in generations:
        if not g.get("repository") or not g.get("branch"):
            raise ValueError("each generation requires repository and branch")
    return data

def classify_change(change: dict[str, Any]) -> str:
    """Return the safest initial migration mode for a declared change."""
    kind = str(change.get("kind", "unknown")).lower()
    if kind in {"docs", "documentation", "metadata"}:
        return "mechanical_candidate"
    if kind in {"bugfix", "security"} and change.get("mapping_verified") is True:
        return "assisted"
    if kind in {"feature", "refactor", "architecture", "unknown"}:
        return "manual"
    return "manual"

def build_plan(config: dict[str, Any], changes: list[dict[str, Any]]) -> dict[str, Any]:
    generations = config["generations"]
    source = config.get("migration", {}).get("source_generation")
    target = config.get("migration", {}).get("target_generation")
    ids = {g["id"] for g in generations}
    if source not in ids or target not in ids or source == target:
        raise ValueError("migration source/target must be distinct configured generations")
    items=[]
    for c in changes:
        items.append({
            "change_id": c.get("id", "UNIDENTIFIED"),
            "kind": c.get("kind", "unknown"),
            "mode": classify_change(c),
            "source_commit": c.get("source_commit"),
            "mapping": c.get("mapping", []),
            "requires_human_review": classify_change(c) != "mechanical_candidate",
            "status": "planned",
        })
    return {
        "engine": "Generational Migration Engine",
        "schema_version": SCHEMA_VERSION,
        "project": config.get("project", {}),
        "source_generation": source,
        "target_generation": target,
        "items": items,
        "safety": {
            "automatic_source_edits": False,
            "human_approval_required_for_semantic_changes": True,
            "verification_required_before_completion": True,
        },
    }

def main() -> int:
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("config")
    p.add_argument("--changes", help="JSON file containing an array of change records")
    p.add_argument("--output", help="Write plan to this file (stdout by default)")
    args=p.parse_args()
    config=load_config(args.config)
    changes=json.loads(Path(args.changes).read_text(encoding="utf-8")) if args.changes else []
    if not isinstance(changes,list):
        raise ValueError("--changes must contain a JSON array")
    plan=build_plan(config,changes)
    rendered=json.dumps(plan,indent=2)+"\n"
    if args.output:
        Path(args.output).write_text(rendered,encoding="utf-8")
    else:
        print(rendered,end="")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
