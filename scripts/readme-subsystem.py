#!/usr/bin/env python3
"""Validate and locally cross-port the forge-neutral README subsystem."""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path, PurePosixPath
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONFIG = ROOT / "config" / "readme-subsystem.json"
PLATFORMS = {"github", "gitlab", "gitea", "forgejo", "codeberg", "generic"}
NAMESPACE_KINDS = {
    "user",
    "organization",
    "group",
    "subgroup",
    "workspace",
    "namespace",
}


class SubsystemError(RuntimeError):
    """Raised when the subsystem contract or a sync request is invalid."""


def safe_relative(value: str, context: str) -> Path:
    candidate = PurePosixPath(value)
    if not value or candidate.is_absolute() or ".." in candidate.parts:
        raise SubsystemError(f"{context} must be a safe relative path: {value!r}")
    return Path(*candidate.parts)


def load_config(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SubsystemError(f"cannot read {path}: {exc}") from exc
    if data.get("schema_version") != 1:
        raise SubsystemError("readme subsystem schema_version must be 1")
    return data


def validate_config(data: dict[str, Any], root: Path) -> list[str]:
    errors: list[str] = []
    projects = data.get("projects")
    artifacts = data.get("artifacts")
    canonical = data.get("canonical_project")
    if not isinstance(projects, dict) or not projects:
        return ["projects must be a non-empty object"]
    if canonical not in projects:
        errors.append("canonical_project must reference a declared project")
    if not isinstance(artifacts, list) or not artifacts:
        errors.append("artifacts must be a non-empty array")
        artifacts = []

    for key, project in projects.items():
        context = f"projects.{key}"
        if not isinstance(project, dict):
            errors.append(f"{context} must be an object")
            continue
        for field in ("namespace", "project", "branch", "role"):
            if not isinstance(project.get(field), str) or not project[field].strip():
                errors.append(f"{context}.{field} must be a non-empty string")
        if project.get("platform") not in PLATFORMS:
            errors.append(f"{context}.platform is unsupported: {project.get('platform')!r}")
        if project.get("namespace_kind") not in NAMESPACE_KINDS:
            errors.append(
                f"{context}.namespace_kind is unsupported: "
                f"{project.get('namespace_kind')!r}"
            )
        parent = project.get("sync_from")
        if parent is not None and parent not in projects:
            errors.append(f"{context}.sync_from references unknown project {parent!r}")

    for key in projects:
        seen: set[str] = set()
        current: str | None = key
        while current is not None:
            if current in seen:
                errors.append(f"sync_from cycle includes project {current!r}")
                break
            seen.add(current)
            value = projects.get(current)
            current = value.get("sync_from") if isinstance(value, dict) else None

    ids: set[str] = set()
    for position, artifact in enumerate(artifacts):
        context = f"artifacts[{position}]"
        if not isinstance(artifact, dict):
            errors.append(f"{context} must be an object")
            continue
        artifact_id = artifact.get("id")
        if not isinstance(artifact_id, str) or not artifact_id:
            errors.append(f"{context}.id must be a non-empty string")
        elif artifact_id in ids:
            errors.append(f"duplicate artifact id {artifact_id!r}")
        else:
            ids.add(artifact_id)
        owner = artifact.get("owner")
        if owner not in projects:
            errors.append(f"{context}.owner references unknown project {owner!r}")
        source = artifact.get("source")
        try:
            source_path = safe_relative(source, f"{context}.source")
        except (SubsystemError, TypeError) as exc:
            errors.append(str(exc))
            source_path = None
        if owner == canonical and source_path is not None and not (root / source_path).is_file():
            errors.append(f"{context}.source does not exist: {source}")
        destinations = artifact.get("destinations")
        if not isinstance(destinations, list) or not destinations:
            errors.append(f"{context}.destinations must be a non-empty array")
            continue
        for number, destination in enumerate(destinations):
            target_context = f"{context}.destinations[{number}]"
            if not isinstance(destination, dict):
                errors.append(f"{target_context} must be an object")
                continue
            target = destination.get("project")
            if target not in projects:
                errors.append(f"{target_context}.project references {target!r}")
            if target == owner:
                errors.append(f"{target_context}.project cannot equal artifact owner")
            try:
                safe_relative(destination.get("path"), f"{target_context}.path")
            except (SubsystemError, TypeError) as exc:
                errors.append(str(exc))
    return sorted(set(errors))


def sync_artifacts(
    data: dict[str, Any],
    source_root: Path,
    target_root: Path,
    target: str,
    check: bool,
) -> list[str]:
    if target not in data["projects"]:
        raise SubsystemError(f"unknown target project: {target}")
    changed: list[str] = []
    canonical = data["canonical_project"]
    for artifact in data["artifacts"]:
        if artifact["owner"] != canonical or artifact.get("delegated_to"):
            continue
        source = source_root / safe_relative(artifact["source"], "artifact source")
        if not source.is_file():
            raise SubsystemError(f"artifact source does not exist: {source}")
        for destination in artifact["destinations"]:
            if destination["project"] != target:
                continue
            relative = safe_relative(destination["path"], "artifact destination")
            output = target_root / relative
            content = source.read_bytes()
            if output.is_file() and output.read_bytes() == content:
                continue
            changed.append(relative.as_posix())
            if not check:
                output.parent.mkdir(parents=True, exist_ok=True)
                output.write_bytes(content)
                output.chmod(source.stat().st_mode & 0o777)
    return sorted(changed)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    subparsers = parser.add_subparsers(dest="command", required=True)
    validate = subparsers.add_parser("validate")
    validate.add_argument("--root", type=Path, default=ROOT)
    plan = subparsers.add_parser("plan")
    plan.add_argument("--target")
    sync = subparsers.add_parser("sync")
    sync.add_argument("--source-root", type=Path, default=ROOT)
    sync.add_argument("--target-root", type=Path, required=True)
    sync.add_argument("--target", required=True)
    sync.add_argument("--check", action="store_true")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        data = load_config(args.config)
        errors = validate_config(data, ROOT)
        if errors:
            for error in errors:
                print(f"ERROR: {error}", file=sys.stderr)
            return 1
        if args.command == "validate":
            print(
                f"README subsystem contract is valid: {len(data['projects'])} "
                f"project(s), {len(data['artifacts'])} artifact(s)."
            )
            return 0
        if args.command == "plan":
            plan = []
            for artifact in data["artifacts"]:
                for destination in artifact["destinations"]:
                    if args.target and destination["project"] != args.target:
                        continue
                    plan.append(
                        {
                            "artifact": artifact["id"],
                            "owner": artifact["owner"],
                            "source": artifact["source"],
                            "target": destination["project"],
                            "destination": destination["path"],
                            "delegated_to": artifact.get("delegated_to"),
                        }
                    )
            print(json.dumps(plan, indent=2))
            return 0
        changed = sync_artifacts(
            data,
            args.source_root.resolve(),
            args.target_root.resolve(),
            args.target,
            args.check,
        )
        for path in changed:
            print(("DRIFT " if args.check else "SYNC ") + path)
        if args.check and changed:
            return 1
        print(f"README subsystem: {len(changed)} file(s) changed.")
        return 0
    except (OSError, SubsystemError) as exc:
        print(f"readme-subsystem: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
