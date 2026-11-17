#!/usr/bin/env python3
"""Validate and deterministically resolve provider-neutral FSA contract templates.

This tool is offline and read-only. A resolved template describes policy; it is
not authorization to perform an operation.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONFIG = ROOT / "config" / "contract-templates.example.json"
SAFETY = {"descriptive", "rehearsal", "read-only", "orchestration", "live-mutation"}
SEMVER = re.compile(r"^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$")


class ContractError(ValueError):
    pass


def load(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ContractError(f"cannot load {path}: {exc}") from exc
    if not isinstance(data, dict) or data.get("schema_version") != 1:
        raise ContractError("document must be an object with schema_version: 1")
    if not isinstance(data.get("templates"), dict) or not data["templates"]:
        raise ContractError("templates must be a non-empty object")
    return data


def validate(data: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    templates = data["templates"]
    for key, item in templates.items():
        where = f"templates.{key}"
        if not isinstance(item, dict):
            errors.append(f"{where} must be an object")
            continue
        if item.get("id") != key or not re.fullmatch(r"[a-z0-9][a-z0-9._-]*", key):
            errors.append(f"{where}.id must equal its stable key and use lowercase identifier syntax")
        if not isinstance(item.get("version"), str) or not SEMVER.fullmatch(item["version"]):
            errors.append(f"{where}.version must be semantic X.Y.Z")
        for field in ("owner",):
            if not isinstance(item.get(field), str) or not item[field].strip():
                errors.append(f"{where}.{field} must be a non-empty string")
        if item.get("safety") not in SAFETY:
            errors.append(f"{where}.safety is unsupported")
        target = item.get("target")
        if not isinstance(target, dict):
            errors.append(f"{where}.target must be an object")
        else:
            for field in ("provider", "repository", "ref"):
                if not isinstance(target.get(field), str) or not target[field].strip():
                    errors.append(f"{where}.target.{field} must be a non-empty string")
        if not isinstance(item.get("operations"), list) or not item["operations"] or not all(
            isinstance(x, str) and x.strip() for x in item.get("operations", [])
        ):
            errors.append(f"{where}.operations must be a non-empty list of strings")
        parents = item.get("extends", [])
        if not isinstance(parents, list) or not all(isinstance(x, str) for x in parents):
            errors.append(f"{where}.extends must be a list of template IDs")
        else:
            for parent in parents:
                if parent not in templates:
                    errors.append(f"{where}.extends references unknown template {parent!r}")
                if parent == key:
                    errors.append(f"{where} cannot extend itself")
        for field in ("permissions",):
            value = item.get(field, [])
            if not isinstance(value, list) or not all(isinstance(x, str) and x.strip() for x in value):
                errors.append(f"{where}.{field} must be a list of non-empty strings")
        limits = item.get("limits", {})
        if not isinstance(limits, dict) or any(
            not isinstance(v, (int, float)) or isinstance(v, bool) or v < 0 for v in limits.values()
        ):
            errors.append(f"{where}.limits must contain only non-negative numbers")
        if "credential_class" in item and not isinstance(item["credential_class"], str):
            errors.append(f"{where}.credential_class must be a string reference, never a secret")
    errors.extend(_cycle_errors(templates))
    return sorted(set(errors))


def _cycle_errors(templates: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    visiting: set[str] = set()
    visited: set[str] = set()

    def visit(key: str) -> None:
        if key in visiting:
            errors.append(f"template inheritance cycle includes {key!r}")
            return
        if key in visited:
            return
        visiting.add(key)
        item = templates.get(key, {})
        for parent in item.get("extends", []) if isinstance(item, dict) else []:
            if parent in templates:
                visit(parent)
        visiting.remove(key)
        visited.add(key)

    for key in templates:
        visit(key)
    return errors


def resolve(data: dict[str, Any], template_id: str) -> dict[str, Any]:
    errors = validate(data)
    if errors:
        raise ContractError("; ".join(errors))
    templates = data["templates"]
    if template_id not in templates:
        raise ContractError(f"unknown template: {template_id}")

    def merge(key: str, stack: set[str]) -> dict[str, Any]:
        if key in stack:
            raise ContractError(f"inheritance cycle at {key}")
        current = templates[key]
        result: dict[str, Any] = {}
        for parent in current.get("extends", []):
            result = _merge_objects(result, merge(parent, stack | {key}))
        child = {k: v for k, v in current.items() if k != "extends"}
        result = _merge_objects(result, child)
        return result

    resolved = merge(template_id, set())
    canonical = json.dumps(resolved, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return {
        "resolved": resolved,
        "sha256": hashlib.sha256(canonical.encode("utf-8")).hexdigest(),
        "authorization": "not-granted",
        "note": "Resolution describes a contract only; a separate scoped authorization is required for every live mutation."
    }


def _merge_objects(base: dict[str, Any], overlay: dict[str, Any]) -> dict[str, Any]:
    result = dict(base)
    for key, value in overlay.items():
        if isinstance(result.get(key), dict) and isinstance(value, dict):
            result[key] = _merge_objects(result[key], value)
        elif isinstance(result.get(key), list) and isinstance(value, list):
            # Ordered union makes composition deterministic without silently
            # discarding inherited permissions or operations.
            result[key] = list(dict.fromkeys(result[key] + value))
        else:
            result[key] = value
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("validate")
    resolve_parser = sub.add_parser("resolve")
    resolve_parser.add_argument("--id", required=True)
    args = parser.parse_args()
    try:
        data = load(args.config)
        errors = validate(data)
        if errors:
            for error in errors:
                print(f"ERROR: {error}", file=sys.stderr)
            return 1
        if args.command == "validate":
            print(f"Valid: {len(data['templates'])} contract template(s)")
            return 0
        print(json.dumps(resolve(data, args.id), indent=2, sort_keys=True))
        return 0
    except ContractError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
