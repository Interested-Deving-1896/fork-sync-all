#!/usr/bin/env python3
"""Repair managed README structure and known stale generated references."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


SECTION_HEADINGS = {
    "architecture": "Architecture",
    "ci": "CI",
    "mirror-chain": "Mirror chain",
    "contributors": "Contributors",
    "origins": "Origins",
    "resources": "Resources",
    "accessibility": "Accessibility",
    "license": "License",
}

WCAG_REFERENCE = (
    "See the [W3C Web Content Accessibility Guidelines (WCAG)]"
    "(https://www.w3.org/WAI/standards-guidelines/wcag/)\n"
    "for the underlying accessibility reference."
)
STALE_ACCESSIBILITY_REFERENCE = re.compile(
    r"See \[DOCS/accessibility\.md\]\(https://github\.com/[^\s)]+/"
    r"blob/[^\s)]+/DOCS/accessibility\.md\) for "
    r"(?:the )?(?:full )?(?:accessibility )?reference\."
)


def repair(content: str) -> str:
    """Add a missing H2 immediately before an existing AI-managed block."""
    had_final_newline = content.endswith("\n")
    updated = content
    for section, heading in SECTION_HEADINGS.items():
        marker = f"<!-- AI:start:{section} -->"
        if marker not in updated:
            continue
        if re.search(rf"^##\s+{re.escape(heading)}\s*$", updated, re.I | re.M):
            continue
        replacement = f"## {heading}\n\n{marker}"
        updated = updated.replace(marker, replacement, 1)
    updated = STALE_ACCESSIBILITY_REFERENCE.sub(WCAG_REFERENCE, updated)
    if had_final_newline and not updated.endswith("\n"):
        updated += "\n"
    return updated


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", help="README path or - for standard input")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if args.path == "-":
        original = sys.stdin.read()
    else:
        original = Path(args.path).read_text(encoding="utf-8")
    updated = repair(original)
    if args.check:
        if updated != original:
            print("README structure requires repair", file=sys.stderr)
            return 1
        return 0
    sys.stdout.write(updated)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
