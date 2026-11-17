#!/usr/bin/env python3
"""Produce deterministic, read-only dependency and reverse-impact reports."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from fsa_stack_linkage import LinkageError, load_registry

ROOT = Path(__file__).resolve().parents[1]


def impact_report(registry: dict[str, Any], node_id: str, direction: str = "both") -> dict[str, Any]:
    """Return direct and transitive graph reachability without implying write authority."""
    nodes = {node["id"]: node for node in registry["nodes"]}
    if node_id not in nodes:
        raise LinkageError(f"unknown node: {node_id}")
    if direction not in {"upstream", "downstream", "both"}:
        raise LinkageError(f"unsupported direction: {direction}")

    adjacency: dict[str, set[str]] = {key: set() for key in nodes}
    for edge in registry["edges"]:
        source, target = edge["from"], edge["to"]
        if direction in {"downstream", "both"}:
            adjacency[source].add(target)
        if direction in {"upstream", "both"}:
            adjacency[target].add(source)

    distances = {node_id: 0}
    frontier = [node_id]
    while frontier:
        current = frontier.pop(0)
        for neighbor in sorted(adjacency[current]):
            if neighbor not in distances:
                distances[neighbor] = distances[current] + 1
                frontier.append(neighbor)

    related = [
        {"id": key, "kind": nodes[key]["kind"], "lifecycle": nodes[key]["lifecycle"],
         "distance": distances[key]}
        for key in sorted(distances) if key != node_id
    ]
    return {
        "report_version": 1,
        "registry_id": registry["registry_id"],
        "registry_schema_version": registry["schema_version"],
        "mode": "read-only-impact-report",
        "query": {"node": node_id, "direction": direction},
        "root": {"id": node_id, "kind": nodes[node_id]["kind"]},
        "related": related,
        "related_count": len(related),
        "write_authority": False,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", type=Path, default=ROOT / "config" / "fsa-stack-linkage.json")
    parser.add_argument("--node", required=True, help="stable node identity to inspect")
    parser.add_argument("--direction", choices=("upstream", "downstream", "both"), default="both")
    parser.add_argument("--format", choices=("json", "text"), default="json")
    args = parser.parse_args()
    try:
        registry = load_registry(args.registry)
        report = impact_report(registry, args.node, args.direction)
    except LinkageError as exc:
        print(f"fsa-stack-linkage-impact: {exc}", file=sys.stderr)
        return 1
    if args.format == "json":
        print(json.dumps(report, sort_keys=True, separators=(",", ":")))
    else:
        print(f"Impact report for {report['root']['id']} ({args.direction})")
        for item in report["related"]:
            print(f"- {item['id']} [{item['kind']}; distance={item['distance']}]")
        print(f"{report['related_count']} related node(s); read-only, no write authority")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
