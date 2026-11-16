#!/usr/bin/env python3
"""Validate and render evidence-backed README programming-language badges."""
from __future__ import annotations

import argparse
import json
import math
import re
import sys
import urllib.parse
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONFIG = ROOT / "config" / "programming-language-badges.json"
COLOR_RE = re.compile(r"^[0-9a-fA-F]{6}$")
LOGO_RE = re.compile(r"^[a-z0-9-]+$")


def load_config(path: Path = DEFAULT_CONFIG) -> dict[str, Any]:
    config = json.loads(path.read_text(encoding="utf-8"))
    if config.get("schema_version") != 1:
        raise ValueError("unsupported programming-language badge schema_version")
    languages = config.get("languages")
    if not isinstance(languages, dict) or not languages:
        raise ValueError("languages must be a non-empty object")
    for name, item in languages.items():
        if not isinstance(name, str) or not name or not isinstance(item, dict):
            raise ValueError("invalid language registry entry")
        if not isinstance(item.get("label"), str) or not item["label"]:
            raise ValueError(f"{name}: label is required")
        if not COLOR_RE.fullmatch(str(item.get("color", ""))):
            raise ValueError(f"{name}: color must be six hexadecimal digits")
        logo = item.get("logo", "")
        if logo and not LOGO_RE.fullmatch(logo):
            raise ValueError(f"{name}: invalid Simple Icons slug")
    return config


def normalize_languages(data: Any) -> dict[str, float]:
    if not isinstance(data, dict):
        raise ValueError("language metadata must be a JSON object")
    result: dict[str, float] = {}
    for name, amount in data.items():
        if not isinstance(name, str) or not name:
            raise ValueError("language names must be non-empty strings")
        if isinstance(amount, bool) or not isinstance(amount, (int, float)) or not math.isfinite(amount) or amount < 0:
            raise ValueError(f"{name}: language metadata value must be a non-negative number")
        if amount:
            result[name] = amount
    return result


def render(config: dict[str, Any], languages: dict[str, float] | None) -> str:
    if languages is None or not languages:
        label = config.get("unknown_label", "Language undetected")
        return f"[![Language: {label}](https://img.shields.io/badge/Language-undetected-808080?style=flat-square)]"
    known = config["languages"]
    rows = []
    unknown = []
    for name, amount in sorted(languages.items(), key=lambda pair: (-pair[1], pair[0].casefold())):
        item = known.get(name)
        if item is None:
            unknown.append(name)
            continue
        label = urllib.parse.quote(str(item["label"]), safe="")
        alt = "Language: " + item["label"]
        image = f"https://img.shields.io/badge/{label}-{item['color']}?style={config.get('badge_style', 'flat-square')}"
        if item.get("logo"):
            image += f"&logo={urllib.parse.quote(item['logo'], safe='')}&logoColor=white"
        rows.append(f"[![{alt}]({image})](https://github.com/github-linguist/linguist)")
    if unknown:
        rows.append("[![Language: Other languages](https://img.shields.io/badge/Other%20languages-unclassified-808080?style=flat-square)](https://github.com/github-linguist/linguist)")
    return " ".join(rows) if rows else f"[![{config.get('unknown_label', 'Language undetected')}](https://img.shields.io/badge/Language-undetected-808080?style=flat-square)]"


def strip_managed(content: str) -> str:
    return "\n".join(
        line for line in content.splitlines()
        if "[![Language:" not in line
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    sub = parser.add_subparsers(dest="command", required=True)
    render_parser = sub.add_parser("render")
    render_parser.add_argument("--languages-json", required=True, help="JSON object returned by the SCM language API")
    sub.add_parser("validate")
    sub.add_parser("strip-managed")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        config = load_config(args.config)
        if args.command == "validate":
            print("programming-language badge registry: valid")
        elif args.command == "render":
            languages = normalize_languages(json.loads(args.languages_json))
            print(render(config, languages))
        else:
            print(strip_managed(sys.stdin.read()))
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"programming-language-badge-registry: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
