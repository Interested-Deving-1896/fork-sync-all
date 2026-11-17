#!/usr/bin/env python3
"""Load and validate the provider-neutral FSA stack-linkage registry.

This module is intentionally read-only. A graph edge is descriptive metadata,
not permission to mutate either endpoint.
"""
from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

IDENTITY = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
NODE_KINDS = {
    "engine", "subsystem", "library", "command", "service", "api", "provider",
    "schema", "contract", "manifest", "configuration", "workflow", "job",
    "script", "template", "artifact", "repository", "branch", "reference",
    "test", "documentation", "dashboard", "agent-interface", "lifecycle-record",
}
EDGE_TYPES = {
    "depends_on", "implements", "exposes_api", "consumes_contract",
    "produces_artifact", "adapts_to", "configured_by", "invoked_by",
    "tested_by", "documented_by", "packages", "derives_from", "supersedes",
    "observes", "synchronizes_to", "reports_to",
}
LIFECYCLE = {"proposed", "existing", "deprecated", "retired", "unknown"}


class LinkageError(ValueError):
    """Raised when a stack-linkage registry cannot be trusted."""


def validate_registry(data: Any) -> list[str]:
    errors: list[str] = []
    if not isinstance(data, dict):
        return ["registry root must be an object"]
    if set(data) != {"schema_version", "registry_id", "mode", "nodes", "edges"}:
        errors.append("registry must contain only schema_version, registry_id, mode, nodes, edges")
    if data.get("schema_version") != 1:
        errors.append("schema_version must be 1")
    if data.get("registry_id") != "fsa.stack-linkage":
        errors.append("registry_id must be fsa.stack-linkage")
    if data.get("mode") != "declaration-only":
        errors.append("mode must be declaration-only; write-capable modes are not supported")
    nodes = data.get("nodes")
    edges = data.get("edges")
    if not isinstance(nodes, list):
        errors.append("nodes must be an array")
        nodes = []
    if not isinstance(edges, list):
        errors.append("edges must be an array")
        edges = []

    node_ids: set[str] = set()
    for index, node in enumerate(nodes):
        label = f"nodes[{index}]"
        if not isinstance(node, dict):
            errors.append(f"{label} must be an object")
            continue
        _check_identity(node.get("id"), f"{label}.id", errors)
        node_id = node.get("id")
        if isinstance(node_id, str):
            if node_id in node_ids:
                errors.append(f"duplicate node id: {node_id}")
            node_ids.add(node_id)
        if node.get("kind") not in NODE_KINDS:
            errors.append(f"{label}.kind is unsupported")
        for field in ("owner", "authority"):
            if not isinstance(node.get(field), str) or not node[field].strip():
                errors.append(f"{label}.{field} must be a non-empty string")
        if node.get("lifecycle") not in LIFECYCLE:
            errors.append(f"{label}.lifecycle is unsupported")
        _check_evidence(node.get("evidence"), f"{label}.evidence", errors)
        allowed = {"id", "kind", "owner", "authority", "lifecycle", "evidence"}
        if set(node) - allowed:
            errors.append(f"{label} contains unsupported fields: {', '.join(sorted(set(node) - allowed))}")

    edge_ids: set[str] = set()
    for index, edge in enumerate(edges):
        label = f"edges[{index}]"
        if not isinstance(edge, dict):
            errors.append(f"{label} must be an object")
            continue
        for field in ("id", "from", "to"):
            _check_identity(edge.get(field), f"{label}.{field}", errors)
        edge_id = edge.get("id")
        if isinstance(edge_id, str):
            if edge_id in edge_ids:
                errors.append(f"duplicate edge id: {edge_id}")
            edge_ids.add(edge_id)
        for endpoint in ("from", "to"):
            value = edge.get(endpoint)
            if isinstance(value, str) and value not in node_ids:
                errors.append(f"{label}.{endpoint} references missing node: {value}")
        if edge.get("type") not in EDGE_TYPES:
            errors.append(f"{label}.type is unsupported")
        if edge.get("direction") not in {"outbound", "inbound"}:
            errors.append(f"{label}.direction must be outbound or inbound")
        if not isinstance(edge.get("owner"), str) or not edge["owner"].strip():
            errors.append(f"{label}.owner must be a non-empty string")
        state = edge.get("state")
        if state not in {"declared", "inferred"}:
            errors.append(f"{label}.state must be declared or inferred")
        _check_evidence(edge.get("evidence"), f"{label}.evidence", errors)
        if state == "inferred":
            confidence = edge.get("confidence")
            if not isinstance(confidence, (int, float)) or isinstance(confidence, bool) or not 0 <= confidence <= 1:
                errors.append(f"{label}.confidence must be a number from 0 to 1")
            if edge.get("unverified") is not True:
                errors.append(f"{label}.unverified must be true for inferred edges")
        elif "confidence" in edge or "unverified" in edge:
            errors.append(f"{label} declared edges must not carry inferred-edge metadata")
        allowed = {"id", "from", "to", "type", "direction", "owner", "state", "evidence", "confidence", "unverified"}
        if set(edge) - allowed:
            errors.append(f"{label} contains unsupported fields: {', '.join(sorted(set(edge) - allowed))}")
    return errors


def _check_identity(value: Any, label: str, errors: list[str]) -> None:
    if not isinstance(value, str) or not IDENTITY.fullmatch(value):
        errors.append(f"{label} must be a stable lowercase identity")


def _check_evidence(value: Any, label: str, errors: list[str]) -> None:
    valid = (
        isinstance(value, list)
        and bool(value)
        and all(isinstance(item, str) and item.strip() for item in value)
        and len(value) == len(set(value))
    )
    if not valid:
        errors.append(f"{label} must be a non-empty array of unique non-empty strings")

def load_registry(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise LinkageError(f"cannot read {path}: {exc}") from exc
    errors = validate_registry(data)
    if errors:
        raise LinkageError("; ".join(errors))
    return data
