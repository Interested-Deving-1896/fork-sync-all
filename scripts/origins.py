"""Shared, read-only Origins provenance parser and normalizer.

This module treats provenance as descriptive data only. It never fetches,
imports, executes, or authorizes anything named by an origin record.
"""
from __future__ import annotations

from pathlib import Path
from typing import Any
from urllib.parse import urlparse

import yaml


VALID_RELATIONSHIPS = {
    "fork", "extracted-logic", "inspired-by", "reference",
    "schema-adopted", "pattern-adopted",
}


class OriginsValidationError(ValueError):
    """Raised when an Origins manifest is malformed or unsafe to consume."""


class _UniqueKeyLoader(yaml.SafeLoader):
    """Safe YAML loader that rejects duplicate mapping keys."""


def _construct_mapping(loader: _UniqueKeyLoader, node: yaml.MappingNode, deep: bool = False):
    loader.flatten_mapping(node)
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in mapping:
            raise OriginsValidationError(f"duplicate YAML mapping key: {key!r}")
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


_UniqueKeyLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _construct_mapping
)


def normalize_manifest(data: Any) -> dict[str, list[dict[str, str]]]:
    """Validate and return a deterministic normalized provenance structure."""
    if not isinstance(data, dict):
        raise OriginsValidationError("manifest root must be a mapping")
    if set(data) != {"influences"}:
        unexpected = sorted(set(data) - {"influences"})
        missing = "influences" not in data
        details = []
        if missing:
            details.append("missing required 'influences' list")
        if unexpected:
            details.append(f"unknown top-level key(s): {', '.join(unexpected)}")
        raise OriginsValidationError("; ".join(details))

    influences = data["influences"]
    if not isinstance(influences, list):
        raise OriginsValidationError("'influences' must be a list")

    normalized: list[dict[str, str]] = []
    seen_sources: set[str] = set()
    allowed_fields = {"source", "url", "relationship", "what", "artifact", "notes"}

    for index, item in enumerate(influences):
        prefix = f"influences[{index}]"
        if not isinstance(item, dict):
            raise OriginsValidationError(f"{prefix} must be a mapping")
        unknown = sorted(set(item) - allowed_fields)
        if unknown:
            raise OriginsValidationError(f"{prefix} has unknown field(s): {', '.join(unknown)}")

        for field in ("source", "url", "relationship", "what"):
            value = item.get(field)
            if not isinstance(value, str) or not value.strip():
                raise OriginsValidationError(f"{prefix}.{field} must be a non-empty string")

        source = item["source"].strip()
        url = item["url"].strip()
        relationship = item["relationship"].strip()
        what = item["what"].strip()

        parts = source.split("/")
        if len(parts) != 2 or any(not part or part in {".", ".."} for part in parts):
            raise OriginsValidationError(f"{prefix}.source must use owner/repository format")
        parsed = urlparse(url)
        if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
            raise OriginsValidationError(f"{prefix}.url must be an HTTPS URL without credentials")
        if parsed.query or parsed.fragment:
            raise OriginsValidationError(f"{prefix}.url must not contain a query or fragment")
        path_parts = [part for part in parsed.path.strip("/").split("/") if part]
        if len(path_parts) != 2 or [p.lower() for p in path_parts] != [p.lower() for p in parts]:
            raise OriginsValidationError(
                f"{prefix}.url path must identify the same owner/repository as source"
            )
        if relationship not in VALID_RELATIONSHIPS:
            raise OriginsValidationError(
                f"{prefix}.relationship {relationship!r} is invalid; "
                f"expected one of: {', '.join(sorted(VALID_RELATIONSHIPS))}"
            )

        key = source.casefold()
        if key in seen_sources:
            raise OriginsValidationError(f"{prefix}.source duplicates an earlier source: {source}")
        seen_sources.add(key)

        record = {
            "source": source,
            "url": url.rstrip("/"),
            "relationship": relationship,
            "what": what,
        }
        for optional in ("artifact", "notes"):
            value = item.get(optional)
            if value is not None:
                if not isinstance(value, str):
                    raise OriginsValidationError(f"{prefix}.{optional} must be a string when present")
                if value.strip():
                    record[optional] = value.strip()
        normalized.append(record)

    normalized.sort(key=lambda record: record["source"].casefold())
    return {"influences": normalized}


def load_manifest(path: str | Path) -> dict[str, list[dict[str, str]]]:
    """Read a local YAML file and return its validated normalized model."""
    manifest_path = Path(path)
    try:
        with manifest_path.open("r", encoding="utf-8") as stream:
            data = yaml.load(stream, Loader=_UniqueKeyLoader)
    except OSError as exc:
        raise OriginsValidationError(f"cannot read {manifest_path}: {exc}") from exc
    except yaml.YAMLError as exc:
        raise OriginsValidationError(f"invalid YAML in {manifest_path}: {exc}") from exc
    return normalize_manifest(data)
