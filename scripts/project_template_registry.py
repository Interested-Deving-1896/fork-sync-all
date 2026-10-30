"""Strict, side-effect-free loader for the versioned project template registry."""
from __future__ import annotations

from pathlib import Path
import re
from typing import Any, Mapping

import yaml

from scripts.project_creation_engine import ProjectSpecError, Template, validate_template


_SEMVER_RE = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
_REGISTRY_SCHEMA_VERSION = "1.0"


class _UniqueKeySafeLoader(yaml.SafeLoader):
    """Safe YAML loader that rejects duplicate mapping keys instead of hiding them."""


def _construct_mapping(loader: _UniqueKeySafeLoader, node: yaml.MappingNode, deep: bool = False) -> dict:
    loader.flatten_mapping(node)
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        try:
            duplicate = key in mapping
        except TypeError as exc:
            raise yaml.constructor.ConstructorError(
                "while constructing a mapping", node.start_mark,
                "found an unhashable mapping key", key_node.start_mark,
            ) from exc
        if duplicate:
            raise yaml.constructor.ConstructorError(
                "while constructing a mapping", node.start_mark,
                f"duplicate key {key!r}", key_node.start_mark,
            )
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


_UniqueKeySafeLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _construct_mapping
)


def parse_registry(raw: Any) -> tuple[Template, ...]:
    """Validate a decoded registry and return templates in declared order."""
    if not isinstance(raw, Mapping):
        raise ProjectSpecError("template registry must be a mapping")
    if raw.get("schema_version") != _REGISTRY_SCHEMA_VERSION:
        raise ProjectSpecError(f"schema_version must be {_REGISTRY_SCHEMA_VERSION!r}")
    entries = raw.get("templates")
    if not isinstance(entries, list) or not entries:
        raise ProjectSpecError("templates must be a non-empty list")

    templates: list[Template] = []
    seen: set[tuple[str, str]] = set()
    for index, entry in enumerate(entries):
        if not isinstance(entry, Mapping):
            raise ProjectSpecError(f"templates[{index}] must be a mapping")
        version = entry.get("version")
        if not isinstance(version, str) or not _SEMVER_RE.fullmatch(version):
            raise ProjectSpecError(f"templates[{index}].version must use semantic x.y.z form")
        source = entry.get("source")
        if (
            not isinstance(source, str)
            or not source.strip()
            or any(ord(char) < 32 or ord(char) == 127 for char in source)
        ):
            raise ProjectSpecError(f"templates[{index}].source must be non-empty and contain no control characters")
        template = validate_template(entry)
        identity = (template.template_id, template.version)
        if identity in seen:
            raise ProjectSpecError(
                f"duplicate template identity: {template.template_id}@{template.version}"
            )
        seen.add(identity)
        templates.append(template)
    return tuple(templates)


def load_registry(path: str | Path) -> tuple[Template, ...]:
    """Read and strictly validate a local YAML registry; performs no network calls."""
    try:
        with Path(path).open("r", encoding="utf-8") as handle:
            raw = yaml.load(handle, Loader=_UniqueKeySafeLoader)
    except (OSError, UnicodeError, yaml.YAMLError) as exc:
        raise ProjectSpecError("unable to read a valid template registry") from exc
    return parse_registry(raw)


def resolve_template(
    templates: tuple[Template, ...] | list[Template], template_id: str, version: str
) -> Template:
    """Resolve an exact ID/version pair; never selects a latest or floating version."""
    if not isinstance(template_id, str) or not template_id.strip():
        raise ProjectSpecError("template_id must be a non-empty string")
    if not isinstance(version, str) or not _SEMVER_RE.fullmatch(version):
        raise ProjectSpecError("template version must use semantic x.y.z form")
    matches = [
        item for item in templates
        if item.template_id == template_id and item.version == version
    ]
    if len(matches) != 1:
        raise ProjectSpecError(f"template version not found: {template_id}@{version}")
    return matches[0]
