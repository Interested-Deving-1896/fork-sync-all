#!/usr/bin/env python3
"""Resolve cleanup-report targets from the validated consumer registry.

Only enabled, managed GitHub consumers are returned. Bare names use the
registry's documented default owner; qualified names retain their explicit
owner. Protected, delegated, and disabled consumers are never targets.
GitLab is intentionally not inferred from comments or legacy ID lists.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Any

import yaml


def resolve_targets(data: dict[str, Any], default_owner: str) -> tuple[list[tuple[str, str]], list[str]]:
    raw = data.get("consumers")
    if not isinstance(raw, list):
        raise ValueError("'consumers' must be a list")

    targets: list[tuple[str, str]] = []
    skipped: list[str] = []
    seen: set[str] = set()

    for index, entry in enumerate(raw, start=1):
        if not isinstance(entry, dict):
            raise ValueError(f"consumer {index} must be a mapping")
        name = entry.get("name")
        if not isinstance(name, str) or not name.strip():
            raise ValueError(f"consumer {index} has no valid name")
        name = name.strip()

        tier = entry.get("tier", "managed")
        if tier not in {"protected", "managed", "delegated"}:
            raise ValueError(f"{name}: invalid tier {tier!r}")
        disabled = entry.get("disabled", False)
        if not isinstance(disabled, bool):
            raise ValueError(f"{name}: disabled must be boolean")

        if disabled:
            skipped.append(f"{name}: disabled")
            continue
        if tier != "managed":
            skipped.append(f"{name}: tier={tier}")
            continue

        if name.count("/") == 0:
            owner, repo = default_owner, name
        elif name.count("/") == 1:
            owner, repo = name.split("/", 1)
        else:
            raise ValueError(f"{name}: expected repo or owner/repo")

        if not owner or not repo or any(ch.isspace() for ch in owner + repo):
            raise ValueError(f"{name}: invalid GitHub owner/repository")
        key = f"{owner}/{repo}".casefold()
        if key in seen:
            raise ValueError(f"{name}: duplicate canonical target {owner}/{repo}")
        seen.add(key)
        targets.append((owner, repo))

    return targets, skipped


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("registry", type=Path, help="template-consumers.yml")
    parser.add_argument("--default-owner", default="Interested-Deving-1896")
    args = parser.parse_args()

    try:
        with args.registry.open(encoding="utf-8") as handle:
            data = yaml.safe_load(handle)
        if not isinstance(data, dict):
            raise ValueError("registry root must be a mapping")
        targets, skipped = resolve_targets(data, args.default_owner)
    except (OSError, yaml.YAMLError, ValueError) as exc:
        print(f"cleanup registry error: {exc}", file=sys.stderr)
        return 2

    for reason in skipped:
        print(f"SKIP {reason}", file=sys.stderr)
    for owner, repo in targets:
        print(f"{owner}\t{repo}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
