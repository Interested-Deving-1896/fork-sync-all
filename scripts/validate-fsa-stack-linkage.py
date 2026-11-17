#!/usr/bin/env python3
"""Validate the canonical FSA stack-linkage registry."""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from fsa_stack_linkage import LinkageError, load_registry

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "registry", nargs="?", type=Path,
        default=ROOT / "config" / "fsa-stack-linkage.json",
    )
    args = parser.parse_args()
    try:
        registry = load_registry(args.registry)
    except LinkageError as exc:
        print(f"validate-fsa-stack-linkage: {exc}", file=sys.stderr)
        return 1
    print(
        "validate-fsa-stack-linkage: "
        f"{len(registry['nodes'])} node(s), {len(registry['edges'])} edge(s) valid "
        "(declaration-only; no write authority)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
