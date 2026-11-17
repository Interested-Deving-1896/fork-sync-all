#!/usr/bin/env python3
"""Read-only structural audit for README ownership markers.

This tool is a preflight auditor, not a renderer or replacement engine.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import re
import sys

MARKER = re.compile(r"^\s*<!--\s*(AI|HUMAN|LTS):(start|end)(?::([A-Za-z0-9_.-]+))?\s*-->\s*$")


def audit(text: str) -> list[str]:
    errors: list[str] = []
    stack: list[tuple[str, str | None, int]] = []
    seen: set[tuple[str, str | None]] = set()

    for number, raw in enumerate(text.splitlines(), 1):
        match = MARKER.fullmatch(raw)
        if not match:
            if "<!--" in raw and re.search(r"\b(AI|HUMAN|LTS):(start|end)", raw):
                errors.append(f"line {number}: malformed ownership marker")
            continue

        kind, edge, name = match.groups()
        if kind == "HUMAN" and name is not None:
            errors.append(f"line {number}: HUMAN markers must not include a section name")
            continue
        if kind != "HUMAN" and name is None:
            errors.append(f"line {number}: malformed {kind} marker: section name is required")
            continue

        key = (kind, name)
        if edge == "start":
            if key in seen:
                errors.append(f"line {number}: duplicate {kind} start marker for {name or 'HUMAN'}")
            seen.add(key)
            stack.append((kind, name, number))
            continue

        if not stack:
            errors.append(f"line {number}: unmatched {kind} end marker for {name or 'HUMAN'}")
            continue
        open_kind, open_name, open_line = stack[-1]
        if (open_kind, open_name) != key:
            errors.append(
                f"line {number}: {kind} end marker for {name or 'HUMAN'} does not match "
                f"open {open_kind} marker for {open_name or 'HUMAN'} from line {open_line}"
            )
            continue
        stack.pop()

    for kind, name, line in stack:
        errors.append(f"line {line}: unclosed {kind} start marker for {name or 'HUMAN'}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="+", type=Path, help="README files to audit")
    args = parser.parse_args()
    failed = False
    for path in args.paths:
        try:
            errors = audit(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError) as exc:
            print(f"{path}: ERROR: {exc}", file=sys.stderr)
            failed = True
            continue
        if errors:
            failed = True
            for error in errors:
                print(f"{path}: {error}", file=sys.stderr)
        else:
            print(f"{path}: OK")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
