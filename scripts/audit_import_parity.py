#!/usr/bin/env python3
"""Read-only comparison of Git branch/tag refs between two Git remotes."""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path


def list_refs(url: str) -> tuple[str | None, dict[str, str]]:
    result = subprocess.run(
        ["git", "ls-remote", "--symref", url, "HEAD", "refs/heads/*", "refs/tags/*"],
        check=True, capture_output=True, text=True,
    )
    default_branch = None
    refs: dict[str, str] = {}
    for line in result.stdout.splitlines():
        fields = line.split("\t", 1)
        if len(fields) != 2:
            continue
        value, name = fields
        if name == "HEAD":
            continue
        if name.startswith("ref: refs/heads/") and value == "HEAD":
            default_branch = name.removeprefix("ref: refs/heads/")
            continue
        if name.endswith("^{}"):
            continue
        if name.startswith(("refs/heads/", "refs/tags/")):
            refs[name] = value
    return default_branch, refs


def compare(source: dict[str, str], target: dict[str, str],
            source_default: str | None, target_default: str | None) -> dict:
    missing = sorted(set(source) - set(target))
    extra = sorted(set(target) - set(source))
    mismatched = sorted(
        name for name in set(source) & set(target) if source[name] != target[name]
    )
    default_branch_present = bool(
        source_default and f"refs/heads/{source_default}" in target
    )
    return {
        "schema_version": 1,
        "mode": "read-only",
        "source_default_branch": source_default,
        "target_default_branch": target_default,
        "source_ref_count": len(source),
        "target_ref_count": len(target),
        "missing_on_target": missing,
        "extra_on_target": extra,
        "mismatched": [
            {"ref": name, "source_sha": source[name], "target_sha": target[name]}
            for name in mismatched
        ],
        "source_default_branch_present_on_target": default_branch_present,
        "parity": not (missing or extra or mismatched) and (
            source_default == target_default and default_branch_present
        ),
        "policy": {
            "writes": False, "force_push": False, "deletions": False,
            "repository_creation": False, "workflow_dispatch": False,
        },
    }


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, help="Source git URL")
    parser.add_argument("--target", required=True, help="Target git URL")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    try:
        source_default, source_refs = list_refs(args.source)
        target_default, target_refs = list_refs(args.target)
    except (OSError, subprocess.CalledProcessError) as exc:
        print(f"ref parity audit failed: {exc}", file=sys.stderr)
        return 2
    report = compare(source_refs, target_refs, source_default, target_default)
    rendered = json.dumps(report, indent=2) + "\n"
    if args.output:
        args.output.write_text(rendered, encoding="utf-8")
    else:
        sys.stdout.write(rendered)
    return 0 if report["parity"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
