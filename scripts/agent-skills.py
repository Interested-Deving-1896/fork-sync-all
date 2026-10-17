#!/usr/bin/env python3
"""Discover, validate, and project AI skills without executing them."""

from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONFIG = ROOT / "config/agent-skills.yml"
NAME_PATTERN = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
KNOWN_FIELDS = {
    "name",
    "description",
    "license",
    "compatibility",
    "metadata",
    "allowed-tools",
}


class SkillsError(Exception):
    """An expected, user-facing skills error."""


@dataclass(frozen=True)
class Policy:
    allowed_roots: tuple[Path, ...]
    allow_symlinks: bool
    max_files: int
    max_bytes: int


def emit(payload: dict[str, Any], exit_code: int = 0) -> None:
    print(json.dumps(payload, indent=2, sort_keys=True))
    raise SystemExit(exit_code)


def load_config(path: Path, workspace: Path) -> tuple[dict[str, Any], Policy]:
    try:
        raw = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    except (OSError, yaml.YAMLError) as exc:
        raise SkillsError(f"cannot load skills config: {exc}") from exc
    if not isinstance(raw, dict) or raw.get("schema_version") != 1:
        raise SkillsError("skills config must use schema_version: 1")
    providers = raw.get("providers") or {}
    if not isinstance(providers, dict) or not providers:
        raise SkillsError("skills config must declare at least one provider")
    for provider_id, provider in providers.items():
        if not isinstance(provider_id, str) or not provider_id:
            raise SkillsError("provider IDs must be non-empty strings")
        if not isinstance(provider, dict):
            raise SkillsError(f"provider '{provider_id}' must be a mapping")
        if provider.get("format", "agent-skills") not in {
            "agent-skills",
            "legacy-markdown",
        }:
            raise SkillsError(
                f"provider '{provider_id}' has unsupported format: {provider.get('format')}"
            )
        discovery_paths = provider.get("discovery_paths") or []
        if not isinstance(discovery_paths, list):
            raise SkillsError(f"provider '{provider_id}' discovery_paths must be a list")
    policy_data = raw.get("policy") or {}
    roots = policy_data.get("allowed_roots") or []
    if not isinstance(roots, list) or not roots:
        raise SkillsError("skills policy must declare allowed_roots")
    allowed = tuple(resolve_workspace_path(workspace, value) for value in roots)
    if not all(is_within(root, workspace) for root in allowed):
        raise SkillsError("configured skill roots must resolve inside the workspace")
    max_files = int(policy_data.get("max_files_per_skill", 100))
    max_bytes = int(policy_data.get("max_bytes_per_skill", 10 * 1024 * 1024))
    if max_files < 1 or max_bytes < 1:
        raise SkillsError("skill file and byte limits must be positive")
    policy = Policy(
        allowed_roots=allowed,
        allow_symlinks=bool(policy_data.get("allow_symlinks", False)),
        max_files=max_files,
        max_bytes=max_bytes,
    )
    return raw, policy


def resolve_workspace_path(workspace: Path, value: Any) -> Path:
    if not isinstance(value, str) or not value.strip():
        raise SkillsError("configured paths must be non-empty strings")
    candidate = Path(value)
    if candidate.is_absolute():
        raise SkillsError(f"configured paths must be workspace-relative: {value}")
    return (workspace / candidate).resolve(strict=False)


def is_within(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def require_allowed(path: Path, policy: Policy) -> Path:
    resolved = path.resolve(strict=False)
    if not any(is_within(resolved, root) for root in policy.allowed_roots):
        raise SkillsError(f"path is outside configured skill roots: {path}")
    return resolved


def parse_frontmatter(path: Path) -> tuple[dict[str, Any], str]:
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        raise SkillsError("SKILL.md must begin with YAML frontmatter")
    try:
        closing = next(index for index, line in enumerate(lines[1:], 1) if line.strip() == "---")
    except StopIteration as exc:
        raise SkillsError("SKILL.md frontmatter is not closed") from exc
    try:
        metadata = yaml.safe_load("\n".join(lines[1:closing])) or {}
    except yaml.YAMLError as exc:
        raise SkillsError(f"invalid SKILL.md frontmatter: {exc}") from exc
    if not isinstance(metadata, dict):
        raise SkillsError("SKILL.md frontmatter must be a mapping")
    return metadata, "\n".join(lines[closing + 1 :]).lstrip()


def validate_metadata(metadata: dict[str, Any]) -> tuple[list[str], list[str]]:
    errors: list[str] = []
    warnings: list[str] = []
    name = metadata.get("name")
    description = metadata.get("description")
    if not isinstance(name, str) or not NAME_PATTERN.fullmatch(name) or len(name) > 64:
        errors.append("name must be 1-64 lowercase letters, digits, or single hyphens")
    if (
        not isinstance(description, str)
        or not description.strip()
        or len(description) > 1024
    ):
        errors.append("description must be a non-empty string of at most 1024 characters")
    compatibility = metadata.get("compatibility")
    if compatibility is not None and (not isinstance(compatibility, str) or len(compatibility) > 500):
        errors.append("compatibility must be a string of at most 500 characters")
    license_name = metadata.get("license")
    if license_name is not None and not isinstance(license_name, str):
        errors.append("license must be a string")
    skill_metadata = metadata.get("metadata")
    if skill_metadata is not None:
        if not isinstance(skill_metadata, dict):
            errors.append("metadata must be a mapping")
        elif not all(
            isinstance(key, str) and isinstance(value, str)
            for key, value in skill_metadata.items()
        ):
            errors.append("metadata keys and values must be strings")
    allowed_tools = metadata.get("allowed-tools")
    if allowed_tools is not None and not isinstance(allowed_tools, str):
        errors.append("allowed-tools must be a space-delimited string")
    unknown = sorted(set(metadata) - KNOWN_FIELDS)
    if unknown:
        warnings.append("unrecognized frontmatter fields: " + ", ".join(unknown))
    return errors, warnings


def inventory(directory: Path, policy: Policy) -> tuple[list[dict[str, Any]], list[str]]:
    files: list[dict[str, Any]] = []
    errors: list[str] = []
    total = 0
    for entry in sorted(directory.rglob("*")):
        if entry.is_symlink() and not policy.allow_symlinks:
            errors.append(f"symbolic links are not allowed: {entry.relative_to(directory)}")
            continue
        if not entry.is_file():
            continue
        size = entry.stat().st_size
        total += size
        files.append({"path": entry.relative_to(directory).as_posix(), "bytes": size})
    if len(files) > policy.max_files:
        errors.append(f"skill contains {len(files)} files; maximum is {policy.max_files}")
    if total > policy.max_bytes:
        errors.append(f"skill contains {total} bytes; maximum is {policy.max_bytes}")
    return files, errors


def validate_package(path: Path, policy: Policy) -> dict[str, Any]:
    directory = require_allowed(path, policy)
    errors: list[str] = []
    warnings: list[str] = []
    metadata: dict[str, Any] = {}
    body = ""
    files: list[dict[str, Any]] = []
    if not directory.is_dir():
        errors.append("skill package must be a directory")
    else:
        entrypoint = directory / "SKILL.md"
        if not entrypoint.is_file():
            errors.append("skill package must contain SKILL.md")
        else:
            try:
                metadata, body = parse_frontmatter(entrypoint)
                metadata_errors, metadata_warnings = validate_metadata(metadata)
                errors.extend(metadata_errors)
                warnings.extend(metadata_warnings)
            except (OSError, UnicodeError, SkillsError) as exc:
                errors.append(str(exc))
        files, inventory_errors = inventory(directory, policy)
        errors.extend(inventory_errors)
    declared_name = metadata.get("name")
    if isinstance(declared_name, str) and declared_name != directory.name:
        errors.append(
            f"directory name '{directory.name}' differs from declared name '{declared_name}'"
        )
    standard_compliant = not errors
    return {
        "ok": standard_compliant,
        "format": "agent-skills",
        "standard_compliant": standard_compliant,
        "path": str(directory),
        "name": declared_name,
        "description": metadata.get("description"),
        "metadata": metadata,
        "body_bytes": len(body.encode("utf-8")),
        "files": files,
        "total_bytes": sum(item["bytes"] for item in files),
        "errors": errors,
        "warnings": warnings,
    }


def legacy_record(path: Path, policy: Policy) -> dict[str, Any]:
    resolved = require_allowed(path, policy)
    text = resolved.read_text(encoding="utf-8")
    fallback_name = resolved.stem.lower().replace("_", "-").replace(" ", "-")
    heading = next(
        (line.lstrip("# ").strip() for line in text.splitlines() if line.startswith("#")),
        fallback_name,
    )
    metadata: dict[str, Any] = {}
    errors: list[str] = []
    warnings = ["legacy Markdown skill; migrate to a SKILL.md package for portability"]
    body = text
    if text.startswith("---\n"):
        try:
            metadata, body = parse_frontmatter(resolved)
            metadata_errors, metadata_warnings = validate_metadata(metadata)
            errors.extend(metadata_errors)
            warnings.extend(metadata_warnings)
        except SkillsError as exc:
            errors.append(str(exc))
    else:
        metadata_errors, _ = validate_metadata(
            {"name": fallback_name, "description": heading}
        )
        errors.extend(metadata_errors)
    name = metadata.get("name", fallback_name)
    description = metadata.get("description", heading)
    if isinstance(name, str) and name != fallback_name:
        errors.append(
            f"file name '{fallback_name}' differs from declared name '{name}'"
        )
    return {
        "ok": not errors,
        "format": "legacy-markdown",
        "standard_compliant": False,
        "path": str(resolved),
        "name": name,
        "description": description,
        "metadata": metadata,
        "body_bytes": len(body.encode("utf-8")),
        "files": [{"path": resolved.name, "bytes": resolved.stat().st_size}],
        "total_bytes": resolved.stat().st_size,
        "errors": errors,
        "warnings": warnings,
    }


def providers_payload(config: dict[str, Any]) -> list[dict[str, Any]]:
    results = []
    for provider_id, value in sorted(config["providers"].items()):
        if not isinstance(value, dict):
            raise SkillsError(f"provider '{provider_id}' must be a mapping")
        fmt = value.get("format", "agent-skills")
        if fmt not in {"agent-skills", "legacy-markdown"}:
            raise SkillsError(f"provider '{provider_id}' has unsupported format: {fmt}")
        results.append(
            {
                "id": provider_id,
                "label": value.get("label", provider_id),
                "format": fmt,
                "discovery_paths": value.get("discovery_paths") or [],
                "export_path": value.get("export_path"),
                "capabilities": ["discover", "inspect", "validate", "export"],
            }
        )
    return results


def discover(
    config: dict[str, Any], policy: Policy, workspace: Path, provider_filter: str = "all"
) -> list[dict[str, Any]]:
    providers = config["providers"]
    if provider_filter != "all" and provider_filter not in providers:
        raise SkillsError(f"unknown provider: {provider_filter}")
    selected = (
        providers.items()
        if provider_filter == "all"
        else [(provider_filter, providers[provider_filter])]
    )
    found: dict[tuple[str, str], dict[str, Any]] = {}
    for provider_id, provider in selected:
        fmt = provider.get("format", "agent-skills")
        for configured_path in provider.get("discovery_paths") or []:
            root = require_allowed(resolve_workspace_path(workspace, configured_path), policy)
            if not root.is_dir():
                continue
            candidates = (
                [item for item in sorted(root.iterdir()) if item.is_dir()]
                if fmt == "agent-skills"
                else sorted(root.glob("*.md"))
            )
            for candidate in candidates:
                try:
                    record = (
                        validate_package(candidate, policy)
                        if fmt == "agent-skills"
                        else legacy_record(candidate, policy)
                    )
                except (OSError, UnicodeError, SkillsError) as exc:
                    record = {
                        "ok": False,
                        "format": fmt,
                        "standard_compliant": False,
                        "path": str(candidate),
                        "name": candidate.stem,
                        "description": None,
                        "errors": [str(exc)],
                        "warnings": [],
                    }
                key = (record["format"], str(Path(record["path"]).resolve(strict=False)))
                if key in found:
                    found[key]["providers"].append(provider_id)
                else:
                    record["providers"] = [provider_id]
                    found[key] = record
    return sorted(found.values(), key=lambda item: (item.get("name") or "", item["path"]))


def find_skill(
    name: str, config: dict[str, Any], policy: Policy, workspace: Path
) -> dict[str, Any]:
    matches = [
        item
        for item in discover(config, policy, workspace)
        if item.get("name") == name
    ]
    canonical = [item for item in matches if item["format"] == "agent-skills"]
    selected = canonical or matches
    if not selected:
        raise SkillsError(f"skill not found: {name}")
    if len(selected) > 1:
        paths = ", ".join(item["path"] for item in selected)
        raise SkillsError(f"skill name is ambiguous ({name}): {paths}")
    return selected[0]


def export_skill(
    name: str,
    provider_id: str,
    config: dict[str, Any],
    policy: Policy,
    workspace: Path,
    materialize: bool,
    replace: bool,
) -> dict[str, Any]:
    providers = config["providers"]
    if provider_id not in providers:
        raise SkillsError(f"unknown provider: {provider_id}")
    provider = providers[provider_id]
    export_path = provider.get("export_path")
    if not export_path:
        raise SkillsError(f"provider does not declare export_path: {provider_id}")
    source = find_skill(name, config, policy, workspace)
    if not source["ok"]:
        raise SkillsError("only valid skill sources can be exported")
    source_path = Path(source["path"])
    destination_root = require_allowed(resolve_workspace_path(workspace, export_path), policy)
    target_format = provider.get("format", "agent-skills")
    if target_format == "agent-skills":
        target = destination_root / name
    elif target_format == "legacy-markdown":
        target = destination_root / f"{name}.md"
    else:
        raise SkillsError(f"unsupported provider format: {target_format}")
    require_allowed(target, policy)
    warnings: list[str] = []
    if target_format == "legacy-markdown" and len(source.get("files", [])) > 1:
        warnings.append(
            "legacy projection includes SKILL.md only; package resources are not copied"
        )
    action = "would-export"
    if materialize:
        if target.resolve(strict=False) == source_path.resolve(strict=False):
            action = "already-installed"
        else:
            if target.exists():
                if not replace:
                    raise SkillsError(f"export target already exists: {target}")
                if target.is_symlink():
                    raise SkillsError(f"refusing to replace symbolic-link target: {target}")
                if target.is_dir():
                    shutil.rmtree(target)
                else:
                    target.unlink()
            target.parent.mkdir(parents=True, exist_ok=True)
            if target_format == "agent-skills":
                if source["format"] == "agent-skills":
                    shutil.copytree(source_path, target)
                else:
                    target.mkdir()
                    shutil.copy2(source_path, target / "SKILL.md")
            else:
                entrypoint = (
                    source_path / "SKILL.md" if source_path.is_dir() else source_path
                )
                shutil.copy2(entrypoint, target)
            action = "exported"
    return {
        "ok": True,
        "action": action,
        "dry_run": not materialize,
        "name": name,
        "provider": provider_id,
        "format": target_format,
        "source": str(source_path),
        "destination": str(target),
        "warnings": warnings,
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--workspace-root", type=Path, default=ROOT)
    commands = parser.add_subparsers(dest="command", required=True)
    list_parser = commands.add_parser("list", help="discover configured skills")
    list_parser.add_argument("--provider", default="all")
    commands.add_parser("providers", help="list provider adapters")
    get_parser = commands.add_parser("get", help="inspect one skill")
    get_parser.add_argument("name")
    validate_parser = commands.add_parser("validate", help="validate a skill package")
    validate_parser.add_argument("path")
    export_parser = commands.add_parser("export", help="project a skill to a provider")
    export_parser.add_argument("name")
    export_parser.add_argument("provider")
    export_parser.add_argument("--materialize", action="store_true")
    export_parser.add_argument("--replace", action="store_true")
    return parser


def main() -> None:
    args = build_parser().parse_args()
    workspace = args.workspace_root.resolve()
    try:
        config, policy = load_config(args.config.resolve(), workspace)
        if args.command == "providers":
            items = providers_payload(config)
            emit({"ok": True, "count": len(items), "items": items})
        if args.command == "list":
            items = discover(config, policy, workspace, args.provider)
            emit({"ok": True, "count": len(items), "items": items})
        if args.command == "get":
            emit({"ok": True, "item": find_skill(args.name, config, policy, workspace)})
        if args.command == "validate":
            path = require_allowed((workspace / args.path).resolve(strict=False), policy)
            result = validate_package(path, policy)
            emit(result, 0 if result["ok"] else 1)
        if args.command == "export":
            emit(
                export_skill(
                    args.name,
                    args.provider,
                    config,
                    policy,
                    workspace,
                    args.materialize,
                    args.replace,
                )
            )
    except SkillsError as exc:
        emit({"ok": False, "error": str(exc)}, 1)


if __name__ == "__main__":
    main()
