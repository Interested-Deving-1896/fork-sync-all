#!/usr/bin/env python3
"""Validate or query the canonical live-chain admission manifest."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from live_chain_manifest import ManifestError, admitted_project_names, load_manifest


ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "manifest",
        nargs="?",
        type=Path,
        default=ROOT / "config" / "live-chain-manifest.json",
    )
    parser.add_argument(
        "--emit-projects",
        action="store_true",
        help="print admitted project names only, one per line",
    )
    parser.add_argument(
        "--source-namespace",
        help="require this GitHub source namespace to match the manifest",
    )
    parser.add_argument(
        "--mirror-namespace",
        action="append",
        default=[],
        help="require an active GitHub mirror namespace to be admitted (repeatable)",
    )
    args = parser.parse_args()
    try:
        manifest = load_manifest(args.manifest)
    except ManifestError as exc:
        print(f"validate-live-chain-manifest: {exc}", file=sys.stderr)
        return 1
    source = manifest["source"]
    mirrors = manifest["mirrors"]
    if args.source_namespace:
        if source["platform"] != "github" or source["namespace"] != args.source_namespace:
            print(
                "validate-live-chain-manifest: active source namespace is not "
                f"admitted: github/{args.source_namespace}",
                file=sys.stderr,
            )
            return 1
    admitted_mirrors = {
        item["namespace"] for item in mirrors if item["platform"] == "github"
    }
    unknown_mirrors = sorted(set(args.mirror_namespace) - admitted_mirrors)
    if unknown_mirrors:
        print(
            "validate-live-chain-manifest: active mirror namespace(s) are not "
            f"admitted: {', '.join(f'github/{value}' for value in unknown_mirrors)}",
            file=sys.stderr,
        )
        return 1
    projects = admitted_project_names(manifest)
    if args.emit_projects:
        print("\n".join(projects))
    else:
        managed = sum(
            project["readme_policy"] == "managed" for project in manifest["projects"]
        )
        print(
            "validate-live-chain-manifest: "
            f"{len(projects)} admitted projects ({managed} managed, "
            f"{len(projects) - managed} exceptions)"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
