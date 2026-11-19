#!/usr/bin/env python3
"""Validate the incremental FSA engine inventory and engine contracts."""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from origins import OriginsValidationError, load_manifest  # noqa: E402

ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
STATUSES = {"discovery", "experimental", "active", "deprecated"}
ENUMS = {
    ("lifecycle",): STATUSES,
    ("ownership",): {"fsa", "external", "mixed"},
    ("origins", "mode"): {"original", "derived", "reference", "mixed"},
    ("runtime", "execution_mode"): {"informational", "local", "remote-opt-in"},
    ("security", "trust"): {"untrusted", "reviewed", "trusted"},
    ("security", "secrets"): {"none", "explicit-opt-in", "protected-only"},
    ("security", "network"): {"none", "declared-only", "restricted", "unrestricted"},
}
REQUIRED = {
    "schema_version", "id", "name", "lifecycle", "ownership", "capabilities",
    "interfaces", "origins", "runtime", "io", "security", "validation",
}


class EngineManifestError(ValueError):
    pass


def read_yaml(path: Path) -> Any:
    try:
        with path.open(encoding="utf-8") as stream:
            return yaml.safe_load(stream)
    except (OSError, yaml.YAMLError) as exc:
        raise EngineManifestError(f"cannot load {path.relative_to(ROOT)}: {exc}") from exc


def require_string_list(value: Any, label: str, *, allow_empty: bool = True) -> None:
    if not isinstance(value, list) or (not allow_empty and not value):
        raise EngineManifestError(f"{label} must be {'a non-empty' if not allow_empty else 'a'} list")
    if any(not isinstance(item, str) or not item.strip() for item in value):
        raise EngineManifestError(f"{label} entries must be non-empty strings")
    if len(value) != len(set(value)):
        raise EngineManifestError(f"{label} contains duplicates")


def validate_manifest(path: Path, known_origins: set[str]) -> str:
    data = read_yaml(path)
    if not isinstance(data, dict):
        raise EngineManifestError(f"{path}: manifest root must be a mapping")
    missing = REQUIRED - set(data)
    unknown = set(data) - REQUIRED - {"dependencies", "notes"}
    if missing or unknown:
        raise EngineManifestError(
            f"{path}: missing={sorted(missing)} unknown={sorted(unknown)}"
        )
    if data["schema_version"] != 1:
        raise EngineManifestError(f"{path}: schema_version must be 1")
    engine_id = data["id"]
    if not isinstance(engine_id, str) or not ID_RE.fullmatch(engine_id):
        raise EngineManifestError(f"{path}: invalid id")
    if not isinstance(data["name"], str) or not data["name"].strip():
        raise EngineManifestError(f"{path}: name must be non-empty")
    for key, allowed in ENUMS.items():
        value: Any = data
        for part in key:
            value = value.get(part) if isinstance(value, dict) else None
        if value not in allowed:
            raise EngineManifestError(f"{path}: {'.'.join(key)} has invalid value {value!r}")
    for field in ("capabilities", "interfaces"):
        require_string_list(data[field], f"{path}: {field}", allow_empty=False)
    for interface in data["interfaces"]:
        kind, separator, target = interface.partition(":")
        if not separator or kind not in {"python-module", "cli", "workflow"}:
            raise EngineManifestError(f"{path}: unsupported interface declaration {interface!r}")
        target_path = (ROOT / target).resolve()
        if ROOT not in target_path.parents or not target_path.is_file():
            raise EngineManifestError(f"{path}: interface target does not exist: {target}")

    origins = data["origins"]
    runtime = data["runtime"]
    io = data["io"]
    security = data["security"]
    validation = data["validation"]
    for section, required in (
        (origins, {"mode", "references"}),
        (runtime, {"execution_mode", "platforms", "toolchains"}),
        (io, {"inputs", "outputs"}),
        (security, {"trust", "permissions", "secrets", "network"}),
        (validation, {"tests", "evidence"}),
    ):
        if not isinstance(section, dict) or set(section) != required:
            raise EngineManifestError(f"{path}: invalid section shape; expected {sorted(required)}")
    require_string_list(origins["references"], f"{path}: origins.references")
    for reference in origins["references"]:
        if reference.casefold() not in known_origins:
            raise EngineManifestError(f"{path}: unknown Origins reference {reference}")
    for field in ("platforms", "toolchains"):
        require_string_list(runtime[field], f"{path}: runtime.{field}")
    for field in ("inputs", "outputs"):
        require_string_list(io[field], f"{path}: io.{field}")
    require_string_list(security["permissions"], f"{path}: security.permissions")
    for field in ("tests", "evidence"):
        require_string_list(validation[field], f"{path}: validation.{field}")
    for test_path in validation["tests"]:
        resolved_test = (ROOT / test_path).resolve()
        if ROOT not in resolved_test.parents or not resolved_test.is_file():
            raise EngineManifestError(f"{path}: declared test file does not exist: {test_path}")
    if "dependencies" in data:
        require_string_list(data["dependencies"], f"{path}: dependencies")
        for dependency in data["dependencies"]:
            if not ID_RE.fullmatch(dependency):
                raise EngineManifestError(f"{path}: invalid dependency id {dependency!r}")
    if "notes" in data and not isinstance(data["notes"], str):
        raise EngineManifestError(f"{path}: notes must be a string")
    if origins["mode"] == "original" and origins["references"]:
        raise EngineManifestError(f"{path}: original engines cannot declare external origin references")
    if origins["mode"] in {"derived", "reference"} and not origins["references"]:
        raise EngineManifestError(f"{path}: {origins['mode']} engines must declare origin references")
    if runtime["execution_mode"] == "remote-opt-in" and security["network"] == "none":
        raise EngineManifestError(f"{path}: remote-opt-in engines must declare network requirements")
    return engine_id


def validate(inventory_path: Path, schema_path: Path) -> list[str]:
    try:
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise EngineManifestError(f"invalid engine schema: {exc}") from exc
    if schema.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
        raise EngineManifestError("engine schema must declare JSON Schema 2020-12")
    inventory = read_yaml(inventory_path)
    if not isinstance(inventory, dict) or set(inventory) != {"schema_version", "manifest_schema", "engines"}:
        raise EngineManifestError("engine inventory has an invalid top-level shape")
    if inventory["schema_version"] != 1 or inventory["manifest_schema"] != str(schema_path.relative_to(ROOT)):
        raise EngineManifestError("engine inventory schema version or schema path is inconsistent")
    entries = inventory["engines"]
    if not isinstance(entries, list) or not entries:
        raise EngineManifestError("engine inventory must contain a non-empty engines list")
    known = {
        item["source"].casefold()
        for item in load_manifest(ROOT / "dep-graph/provenance.yml")["influences"]
    }
    seen: set[str] = set()
    results: list[str] = []
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {"id", "manifest", "status"}:
            raise EngineManifestError("each inventory entry must contain exactly id, manifest, status")
        engine_id = entry["id"]
        if engine_id in seen:
            raise EngineManifestError(f"duplicate engine id {engine_id}")
        if entry["status"] not in STATUSES:
            raise EngineManifestError(f"invalid inventory status for {engine_id}")
        manifest_path = (ROOT / entry["manifest"]).resolve()
        if ROOT not in manifest_path.parents or not manifest_path.is_file():
            raise EngineManifestError(f"missing or unsafe manifest path for {engine_id}")
        validated_id = validate_manifest(manifest_path, known)
        if validated_id != engine_id:
            raise EngineManifestError(f"inventory id {engine_id} does not match manifest id {validated_id}")
        if entry["status"] != read_yaml(manifest_path)["lifecycle"]:
            raise EngineManifestError(f"inventory status does not match lifecycle for {engine_id}")
        seen.add(engine_id)
        results.append(engine_id)
    for entry in entries:
        manifest_path = (ROOT / entry["manifest"]).resolve()
        manifest = read_yaml(manifest_path)
        for dependency in manifest.get("dependencies", []):
            if dependency not in seen:
                raise EngineManifestError(
                    f"{manifest_path}: unknown engine dependency {dependency!r}"
                )
            if dependency == manifest["id"]:
                raise EngineManifestError(f"{manifest_path}: engine cannot depend on itself")
    return sorted(results)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inventory", type=Path, default=ROOT / "config/engine-inventory.yml")
    parser.add_argument("--schema", type=Path, default=ROOT / "config/engine-manifest.schema.json")
    args = parser.parse_args()
    try:
        engines = validate(args.inventory.resolve(), args.schema.resolve())
    except (EngineManifestError, OriginsValidationError) as exc:
        print(f"engine manifest validation failed: {exc}", file=sys.stderr)
        return 1
    print(f"Validated {len(engines)} engine manifest(s): {', '.join(engines)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
