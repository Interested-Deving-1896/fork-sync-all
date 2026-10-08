#!/usr/bin/env python3
"""Validate Fork-Sync-All template profiles and consumer routes."""

from __future__ import annotations

import os
import re
import sys
from typing import Any

import yaml


REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_MANIFEST = os.path.join(REPO_ROOT, "config", "template-manifest.yml")
DEFAULT_CONSUMERS = os.path.join(REPO_ROOT, "config", "template-consumers.yml")
PROJECT_RE = re.compile(
    r"^(?:[a-zA-Z0-9][a-zA-Z0-9._-]{0,99}/)?"
    r"[a-zA-Z0-9][a-zA-Z0-9._-]{0,99}$"
)
BOOL_FIELDS = {"force", "skip_osp_setup", "disabled"}
LIST_FIELDS = {"exclude_paths", "include_paths"}
KNOWN_CONSUMER_FIELDS = {
    "name", "profile", "exclude_paths", "include_paths", "force",
    "skip_osp_setup", "disabled", "tier", "delegated_to",
    "af_registry_repo", "af_registry_branch", "af_registry_path",
}
VALID_TIERS = {"protected", "managed", "delegated"}


def load_yaml(path: str, label: str, errors: list[str]) -> dict[str, Any]:
    if not os.path.exists(path):
        errors.append(f"{label} not found: {path}")
        return {}
    try:
        with open(path, encoding="utf-8") as handle:
            data = yaml.safe_load(handle)
    except (OSError, yaml.YAMLError) as exc:
        errors.append(f"{label} is invalid YAML: {exc}")
        return {}
    if data is None:
        return {}
    if not isinstance(data, dict):
        errors.append(f"{label} root must be a mapping")
        return {}
    return data


def validate_manifest(data: dict[str, Any], errors: list[str]) -> dict[str, dict[str, Any]]:
    raw = data.get("profiles", {}) or {}
    if not isinstance(raw, dict):
        errors.append("template-manifest.yml: 'profiles' must be a mapping")
        return {}
    profiles: dict[str, dict[str, Any]] = {}
    for raw_name, profile in raw.items():
        name = str(raw_name)
        prefix = f"manifest profile '{name}'"
        if not isinstance(profile, dict):
            errors.append(f"{prefix}: value must be a mapping")
            continue
        profiles[name] = profile
        description = profile.get("description")
        if not isinstance(description, str) or not description.strip():
            errors.append(f"{prefix}: missing or empty 'description'")
        for field in ("include", "exclude", "force_update"):
            values = profile.get(field, []) or []
            if not isinstance(values, list):
                errors.append(f"{prefix}: '{field}' must be a list")
                continue
            for index, pattern in enumerate(values):
                if not isinstance(pattern, str) or not pattern.strip():
                    errors.append(f"{prefix}: {field}[{index}] must be a non-empty string")
    if profiles and "full" not in profiles:
        errors.append(
            "template-manifest.yml: 'full' profile is missing — it is the implicit "
            "default for consumers that don't specify a profile"
        )
    return profiles


def validate_consumers(
    data: dict[str, Any], profiles: dict[str, dict[str, Any]],
    errors: list[str], warnings: list[str]
) -> list[dict[str, Any]]:
    raw = data.get("consumers", []) or []
    if not isinstance(raw, list):
        errors.append("template-consumers.yml: 'consumers' must be a list")
        return []
    consumers: list[dict[str, Any]] = []
    seen: set[str] = set()
    for position, consumer in enumerate(raw, start=1):
        if not isinstance(consumer, dict):
            errors.append(f"consumer {position}: value must be a mapping")
            continue
        consumers.append(consumer)
        name = consumer.get("name")
        if not isinstance(name, str) or not name.strip():
            errors.append(f"consumer {position}: missing required field 'name'")
            continue
        name = name.strip()
        prefix = f"consumer '{name}'"
        if name in seen:
            errors.append(f"{prefix}: duplicate consumer name")
        seen.add(name)
        if not PROJECT_RE.fullmatch(name):
            errors.append(
                f"{prefix}: not a valid project name (bare 'project' or "
                "'namespace/project', 1-100 characters per segment)"
            )
        profile = consumer.get("profile", "full")
        if not isinstance(profile, str) or (profiles and profile not in profiles):
            errors.append(
                f"{prefix}: profile '{profile}' is not defined in template-manifest.yml. "
                f"Known profiles: {', '.join(sorted(profiles))}"
            )
        for field in LIST_FIELDS:
            value = consumer.get(field)
            if value is None:
                continue
            if not isinstance(value, list):
                errors.append(f"{prefix}: '{field}' must be a list")
                continue
            for index, pattern in enumerate(value):
                if not isinstance(pattern, str) or not pattern.strip():
                    errors.append(f"{prefix}: {field}[{index}] must be a non-empty string")
        for field in BOOL_FIELDS:
            if field in consumer and not isinstance(consumer[field], bool):
                errors.append(f"{prefix}: '{field}' must be a boolean (true/false)")
        tier = consumer.get("tier", "managed")
        if tier not in VALID_TIERS:
            errors.append(
                f"{prefix}: invalid tier '{tier}' (must be one of: "
                f"{', '.join(sorted(VALID_TIERS))})"
            )
        delegated_to = consumer.get("delegated_to")
        if tier == "delegated":
            if (
                not isinstance(delegated_to, str)
                or not PROJECT_RE.fullmatch(delegated_to)
                or "/" not in delegated_to
            ):
                errors.append(f"{prefix}: delegated tier requires qualified 'delegated_to'")
            elif delegated_to == name:
                errors.append(f"{prefix}: delegated_to cannot reference itself")
        elif delegated_to is not None:
            errors.append(f"{prefix}: delegated_to is only valid for delegated tier")
        for field in consumer:
            if field not in KNOWN_CONSUMER_FIELDS:
                warnings.append(f"{prefix}: unknown field '{field}'")
    return consumers


def main() -> int:
    manifest_path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_MANIFEST
    consumers_path = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_CONSUMERS
    errors: list[str] = []
    warnings: list[str] = []
    manifest = load_yaml(manifest_path, "template-manifest.yml", errors)
    consumers_data = load_yaml(consumers_path, "template-consumers.yml", errors)
    profiles = validate_manifest(manifest, errors)
    consumers = validate_consumers(consumers_data, profiles, errors, warnings)
    for warning in warnings:
        print(f"  ⚠ {warning}")
    if errors:
        print(f"\nvalidate-template-config: {len(errors)} error(s)\n")
        for error in errors:
            print(f"  ✗ {error}")
        return 1
    print(
        f"validate-template-config: {len(profiles)} profile(s) valid, "
        f"{len(consumers)} consumer(s) valid"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
