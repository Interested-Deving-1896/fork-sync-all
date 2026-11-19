#!/usr/bin/env python3
"""Validate dep-graph/provenance.yml using the shared Origins model."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from origins import OriginsValidationError, load_manifest

REPO_ROOT = Path(__file__).resolve().parent.parent


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", nargs="?", default=str(REPO_ROOT / "dep-graph/provenance.yml"))
    parser.add_argument("--json", action="store_true", help="print normalized JSON")
    args = parser.parse_args()
    try:
        model = load_manifest(args.manifest)
    except OriginsValidationError as exc:
        print(f"Origins validation failed: {exc}", file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps(model, indent=2, sort_keys=True))
    else:
        print(f"Origins manifest valid: {len(model['influences'])} unique influence(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
