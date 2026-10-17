#!/usr/bin/env python3
"""Validation and query helpers for the canonical live-chain manifest."""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any


PROJECT_NAME = re.compile(r"^[A-Za-z0-9_.-]+$")
SUPPORTED_PLATFORMS = {"github", "gitlab", "gitea", "forgejo", "codeberg"}
README_POLICIES = {"managed", "exception"}


class ManifestError(ValueError):
    """Raised when the live-chain admission contract is invalid."""


def load_manifest(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ManifestError(f"cannot read {path}: {exc}") from exc
    errors = validate_manifest(data)
    if errors:
        raise ManifestError("; ".join(errors))
    return data


def validate_manifest(data: Any) -> list[str]:
    errors: list[str] = []
    if not isinstance(data, dict):
        return ["manifest root must be an object"]
    if data.get("schema_version") != 1:
        errors.append("schema_version must be 1")

    coordinates: set[tuple[str, str]] = set()
    source = data.get("source")
    _validate_coordinate(source, "source", errors, coordinates)
    mirrors = data.get("mirrors")
    if not isinstance(mirrors, list) or not mirrors:
        errors.append("mirrors must be a non-empty array")
    else:
        for index, mirror in enumerate(mirrors):
            _validate_coordinate(mirror, f"mirrors[{index}]", errors, coordinates)

    projects = data.get("projects")
    if not isinstance(projects, list) or not projects:
        errors.append("projects must be a non-empty array")
        return errors
    seen: set[str] = set()
    previous = ""
    for index, project in enumerate(projects):
        label = f"projects[{index}]"
        if not isinstance(project, dict):
            errors.append(f"{label} must be an object")
            continue
        name = project.get("name")
        if not isinstance(name, str) or not PROJECT_NAME.fullmatch(name):
            errors.append(f"{label}.name must be a valid project name")
            continue
        if name in seen:
            errors.append(f"duplicate project: {name}")
        seen.add(name)
        if previous and name < previous:
            errors.append("projects must be sorted lexicographically by name")
        previous = name
        readme_policy = project.get("readme_policy")
        if readme_policy not in README_POLICIES:
            errors.append(
                f"{label}.readme_policy must be one of: {', '.join(sorted(README_POLICIES))}"
            )
        reason = project.get("reason")
        if readme_policy == "exception" and (
            not isinstance(reason, str) or not reason.strip()
        ):
            errors.append(f"{label}.reason is required for an exception")
        if readme_policy == "managed" and reason is not None:
            errors.append(f"{label}.reason is only valid for an exception")
    return errors


def _validate_coordinate(
    value: Any,
    label: str,
    errors: list[str],
    coordinates: set[tuple[str, str]],
) -> None:
    if not isinstance(value, dict):
        errors.append(f"{label} must be an object")
        return
    platform = value.get("platform")
    namespace = value.get("namespace")
    if platform not in SUPPORTED_PLATFORMS:
        errors.append(
            f"{label}.platform must be one of: {', '.join(sorted(SUPPORTED_PLATFORMS))}"
        )
    if not isinstance(namespace, str) or not namespace.strip():
        errors.append(f"{label}.namespace must be a non-empty string")
        return
    coordinate = (str(platform), namespace)
    if coordinate in coordinates:
        errors.append(f"duplicate chain coordinate: {platform}/{namespace}")
    coordinates.add(coordinate)


def project_index(manifest: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {project["name"]: project for project in manifest["projects"]}


def admitted_project_names(manifest: dict[str, Any]) -> list[str]:
    return [project["name"] for project in manifest["projects"]]
