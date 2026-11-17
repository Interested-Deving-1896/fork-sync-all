#!/usr/bin/env python3
"""Read-only structural audit for README ownership markers.

This is a preflight auditor, not a renderer or replacement engine. It never
rewrites README content and deliberately does not alter update-readmes.sh.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import re
import sys

MARKER = re.compile(r"^\\s*<!--\\s*(AI|HUMAN|LTS):(start|end)(?::([A-Za-z0-9_.-]+))?\\s*-->\\s*$")


@dataclass(frozen=True)
class Frame:
    kind: str
    name: str | None
    line: int


def audit(text: str) -> list[str]:
    errors: list[str] = []
    stack: list[Frame] = []
    seen: set[tuple[str, str | None]] = set()

    for number, raw in enumerate(text.splitlines(), 1):
        match = MARKER.fullmatch(raw)
        if not match:
            # A marker-like comment that almost matches is likely a typo.
            if "<!--" in raw and re.search(r"\\b(AI|HUMAN|LTS):(start|end)", raw):
                errors.append(f"line {number}: malformed ownership marker")
            continue

        kind, edge, name = match.groups()
        if (kind == "HUMAN") != (name is None):
            errors.append(f"line {number}: {kind} markers {'must not' if kind == 'HUMAN' else 'must'} include a section name")
            continue

        key = (kind, name)
        if edge == "start":
            if key in seen:
                errors.append(f"line {number}: duplicate {kind} start marker for {name or 'HUMAN'}")
            seen.add(key)
            stack.append(Frame(kind, name, number))
            continue

        if not stack:
            errors.append(f"line {number}: unmatched {kind} end marker for {name or 'HUMAN'}")
            continue
        top = stack[-1]
        if (top.kind, top.name) != key:
            errors.append(
                f"line {number}: {kind} end marker for {name or 'HUMAN'} does not match "
                f"open {top.kind} marker for {top.name or 'HUMAN'} from line {top.line}"
            )
            continue
        stack.pop()

    for frame in stack:
        errors.append(f"line {frame.line}: unclosed {frame.kind} start marker for {frame.name or 'HUMAN'}")
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
