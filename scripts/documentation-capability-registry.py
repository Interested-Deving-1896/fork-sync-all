#!/usr/bin/env python3
"""Validate and render verified, provider-neutral documentation capabilities."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONFIG = ROOT / "config" / "documentation-capabilities.json"
CAPABILITY_LABELS = {
    "read_aloud": "Read aloud",
    "braille": "Braille-ready view",
}


def _https_url(value: Any, context: str) -> None:
    parsed = urlparse(value) if isinstance(value, str) else None
    if not parsed or parsed.scheme != "https" or not parsed.netloc:
        raise ValueError(f"{context} must be an absolute HTTPS URL")


def validate(config: dict[str, Any]) -> dict[str, Any]:
    if config.get("schema_version") != 1:
        raise ValueError("unsupported documentation-capabilities schema_version")
    default_language = config.get("default_language")
    if not isinstance(default_language, str) or not default_language:
        raise ValueError("default_language must be a non-empty BCP-47 identifier")
    documents = config.get("documents")
    if not isinstance(documents, dict) or not documents:
        raise ValueError("documents must be a non-empty object")

    for document_id, document in documents.items():
        if not isinstance(document_id, str) or not document_id:
            raise ValueError("document IDs must be non-empty strings")
        _https_url(document.get("canonical"), f"{document_id}.canonical")
        formats = document.get("formats", {})
        if not isinstance(formats, dict):
            raise ValueError(f"{document_id}.formats must be an object")
        for format_id, target in formats.items():
            if not isinstance(format_id, str) or not format_id:
                raise ValueError(f"{document_id} has an empty format ID")
            _https_url(target, f"{document_id}.formats.{format_id}")

        translations = document.get("translations", {})
        if not isinstance(translations, dict):
            raise ValueError(f"{document_id}.translations must be an object")
        for language, entry in translations.items():
            if not isinstance(language, str) or not language or not isinstance(entry, dict):
                raise ValueError(f"{document_id} has an invalid translation entry")
            if not isinstance(entry.get("label"), str) or not entry["label"].strip():
                raise ValueError(f"{document_id}.{language} requires a localized label")
            if entry.get("verified") is True:
                _https_url(entry.get("url"), f"{document_id}.{language}.url")

        capabilities = document.get("capabilities", {})
        if not isinstance(capabilities, dict):
            raise ValueError(f"{document_id}.capabilities must be an object")
        for capability, entry in capabilities.items():
            if capability not in CAPABILITY_LABELS:
                raise ValueError(f"unsupported capability: {capability}")
            if not isinstance(entry, dict):
                raise ValueError(f"{document_id}.{capability} must be an object")
            if entry.get("enabled") is True:
                if entry.get("verified") is not True:
                    raise ValueError(f"{document_id}.{capability} cannot be enabled unless verified")
                _https_url(entry.get("url"), f"{document_id}.{capability}.url")
    return config


def load_config(path: Path = DEFAULT_CONFIG) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        return validate(json.load(handle))


def _markdown_link(label: str, url: str) -> str:
    # Reject Markdown destination delimiters rather than emitting ambiguous links.
    if any(char in url for char in ("(", ")", "<", ">", " ", "\n", "\r")):
        raise ValueError("URL contains unsupported Markdown destination characters")
    safe_label = label.replace("[", "\\[").replace("]", "\\]")
    return f"[{safe_label}]({url})"


def render(config: dict[str, Any], document_id: str, language: str | None = None) -> str:
    validate(config)
    try:
        document = config["documents"][document_id]
    except KeyError as exc:
        raise ValueError(f"unknown document: {document_id}") from exc

    selected = language or config["default_language"]
    translations = document.get("translations", {})
    lines: list[str] = []
    current = translations.get(selected)
    if current and current.get("verified") is True:
        lines.append(_markdown_link(current["label"], current["url"]))
    else:
        fallback = translations.get(config["default_language"])
        if fallback and fallback.get("verified") is True:
            lines.append(_markdown_link(fallback["label"], fallback["url"]))

    for capability, label in CAPABILITY_LABELS.items():
        entry = document.get("capabilities", {}).get(capability, {})
        if entry.get("enabled") is True and entry.get("verified") is True:
            lines.append(_markdown_link(entry.get("label", label), entry["url"]))

    for format_id, target in document.get("formats", {}).items():
        lines.append(_markdown_link(format_id, target))
    return " · ".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--document")
    parser.add_argument("--language")
    parser.add_argument("--validate", action="store_true")
    args = parser.parse_args()
    try:
        config = load_config(args.config)
        if args.validate:
            print("documentation capability manifest: valid")
        if args.document:
            print(render(config, args.document, args.language))
        if not args.validate and not args.document:
            parser.error("provide --validate and/or --document")
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"documentation-capability-registry: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
