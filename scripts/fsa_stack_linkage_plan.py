#!/usr/bin/env python3
"""Build deterministic, non-executable FSA synchronization plans."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from fsa_stack_linkage import LinkageError, load_registry

ROOT = Path(__file__).resolve().parents[1]
ARTIFACT_CLASSES = {"code", "configuration", "documentation", "metadata", "template", "workflow"}
DIRECTIONS = {"source-to-target", "target-to-source", "bidirectional"}
COMPATIBILITY = {"compatible", "incompatible", "unknown"}
CONFLICT_POLICIES = {"fail", "report"}


def build_plan(
    registry: dict[str, Any], *, source: str, target: str, artifacts: list[str],
    direction: str = "source-to-target", compatibility: str = "unknown",
    conflict_policy: str = "fail", owner: str = "",
) -> dict[str, Any]:
    """Describe a proposed transfer; this function never executes or authorizes it."""
    nodes = {node["id"]: node for node in registry["nodes"]}
    if source not in nodes:
        raise LinkageError(f"unknown source node: {source}")
    if target not in nodes:
        raise LinkageError(f"unknown target node: {target}")
    if source == target:
        raise LinkageError("source and target must be different nodes")
    if not artifacts or any(item not in ARTIFACT_CLASSES for item in artifacts):
        raise LinkageError("artifacts must be a non-empty list of supported artifact classes")
    if len(artifacts) != len(set(artifacts)):
        raise LinkageError("artifact classes must be unique")
    if direction not in DIRECTIONS:
        raise LinkageError(f"unsupported direction: {direction}")
    if compatibility not in COMPATIBILITY:
        raise LinkageError(f"unsupported compatibility: {compatibility}")
    if conflict_policy not in CONFLICT_POLICIES:
        raise LinkageError(f"unsupported conflict policy: {conflict_policy}")
    if not isinstance(owner, str) or not owner.strip():
        raise LinkageError("owner must be a non-empty string")

    status = "candidate" if compatibility == "compatible" else "blocked"
    reasons = [] if status == "candidate" else [f"compatibility is {compatibility}; manual assessment required"]
    return {
        "plan_version": 1,
        "registry_id": registry["registry_id"],
        "registry_schema_version": registry["schema_version"],
        "mode": "dry-run",
        "status": status,
        "route": {
            "source": source,
            "target": target,
            "direction": direction,
            "artifact_classes": sorted(artifacts),
            "compatibility": compatibility,
            "conflict_policy": conflict_policy,
            "owner": owner.strip(),
        },
        "source": {"id": source, "kind": nodes[source]["kind"], "lifecycle": nodes[source]["lifecycle"]},
        "target": {"id": target, "kind": nodes[target]["kind"], "lifecycle": nodes[target]["lifecycle"]},
        "reasons": reasons,
        "execution_permitted": False,
        "write_authority": False,
        "side_effects": [],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", type=Path, default=ROOT / "config" / "fsa-stack-linkage.json")
    parser.add_argument("--source", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--artifact", action="append", required=True, dest="artifacts")
    parser.add_argument("--direction", choices=sorted(DIRECTIONS), default="source-to-target")
    parser.add_argument("--compatibility", choices=sorted(COMPATIBILITY), default="unknown")
    parser.add_argument("--conflict-policy", choices=sorted(CONFLICT_POLICIES), default="fail")
    parser.add_argument("--owner", required=True)
    args = parser.parse_args()
    try:
        registry = load_registry(args.registry)
        plan = build_plan(
            registry, source=args.source, target=args.target, artifacts=args.artifacts,
            direction=args.direction, compatibility=args.compatibility,
            conflict_policy=args.conflict_policy, owner=args.owner,
        )
    except LinkageError as exc:
        print(f"fsa-stack-linkage-plan: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(plan, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
