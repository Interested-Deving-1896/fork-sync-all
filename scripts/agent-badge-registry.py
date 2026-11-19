#!/usr/bin/env python3
"""Render and migrate provider-neutral README agent badges."""

from __future__ import annotations

import argparse
import json
import sys
import urllib.parse
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONFIG = ROOT / "config" / "ai-agent-badges.json"


def load_config(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        config = json.load(handle)
    if config.get("schema_version") != 1:
        raise ValueError("unsupported ai-agent-badges schema_version")

    entries = [config.get("universal", {})] + list(config.get("providers", []))
    seen: set[str] = set()
    for entry in entries:
        entry_id = entry.get("id")
        if not isinstance(entry_id, str) or not entry_id:
            raise ValueError("every badge entry requires a non-empty id")
        if entry_id in seen:
            raise ValueError(f"duplicate badge id: {entry_id}")
        seen.add(entry_id)
        label = entry.get("label")
        if not isinstance(label, str) or not label:
            raise ValueError(f"badge {entry_id} has invalid label")
        for field in ("image_url", "launch_url"):
            value = entry.get(field)
            if not isinstance(value, str) or not value.startswith("https://"):
                raise ValueError(f"badge {entry_id} has invalid {field}")
    return config


def expand(value: str, repo_url: str) -> str:
    return value.replace("{repo_url}", repo_url).replace(
        "{repo_url_encoded}", urllib.parse.quote(repo_url, safe="")
    )


def enabled_entries(config: dict[str, Any]) -> list[dict[str, Any]]:
    entries = [config["universal"], *config.get("providers", [])]
    return [entry for entry in entries if entry.get("enabled", True)]


def render(config: dict[str, Any], repo_url: str) -> str:
    lines = []
    for entry in enabled_entries(config):
        label = entry["label"]
        image_url = expand(entry["image_url"], repo_url)
        launch_url = expand(entry["launch_url"], repo_url)
        lines.append(f"[![{label}]({image_url})]({launch_url})")
    return "\n".join(lines)


def managed_markers(config: dict[str, Any]) -> list[str]:
    markers = list(config.get("legacy_markers", []))
    markers.extend(entry["image_url"] for entry in enabled_entries(config))
    return markers


def strip_managed(config: dict[str, Any], content: str) -> str:
    markers = managed_markers(config)
    return "\n".join(
        line for line in content.splitlines() if not any(marker in line for marker in markers)
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    subparsers = parser.add_subparsers(dest="command", required=True)

    render_parser = subparsers.add_parser("render")
    render_parser.add_argument("--repo-url", default="")
    subparsers.add_parser("required-marker")
    subparsers.add_parser("managed-markers")
    subparsers.add_parser("strip-managed")
    subparsers.add_parser("validate")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        config = load_config(args.config)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"agent-badge-registry: {exc}", file=sys.stderr)
        return 1

    if args.command == "render":
        print(render(config, args.repo_url))
    elif args.command == "required-marker":
        print(config["universal"]["image_url"])
    elif args.command == "managed-markers":
        print("\n".join(managed_markers(config)))
    elif args.command == "strip-managed":
        print(strip_managed(config, sys.stdin.read()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
