#!/usr/bin/env python3
"""Validate one complete GitHub open-pull-request listing page.

Input is the raw JSON array returned by GET /repos/{owner}/{repo}/pulls.
Output is one normalized JSON object per PR. Any malformed entry, duplicate
number, or unexpected response shape fails the whole page so callers cannot
silently process a partial or truncated listing.
"""

from __future__ import annotations

import json
import re
import sys
from typing import Any


SHA_RE = re.compile(r"^[0-9a-fA-F]{40}$")


def fail(message: str) -> "NoReturn":
    print(f"parse-pr-branch-list: {message}", file=sys.stderr)
    raise SystemExit(2)


def main() -> int:
    try:
        payload: Any = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        fail(f"invalid JSON: {exc}")

    if not isinstance(payload, list):
        fail("expected a JSON array")

    seen: set[int] = set()
    normalized: list[dict[str, Any]] = []
    for index, pr in enumerate(payload):
        where = f"entry {index}"
        if not isinstance(pr, dict):
            fail(f"{where} is not an object")

        number = pr.get("number")
        if isinstance(number, bool) or not isinstance(number, int) or number < 1:
            fail(f"{where} has an invalid PR number")
        if number in seen:
            fail(f"duplicate PR number #{number} in page")
        seen.add(number)

        if pr.get("state") != "open":
            fail(f"PR #{number} is not open in an open-PR listing")

        head = pr.get("head")
        base = pr.get("base")
        if not isinstance(head, dict) or not isinstance(base, dict):
            fail(f"PR #{number} is missing head/base metadata")

        head_ref = head.get("ref")
        head_sha = head.get("sha")
        base_ref = base.get("ref")
        if not isinstance(head_ref, str) or not head_ref:
            fail(f"PR #{number} has an invalid head ref")
        if not isinstance(head_sha, str) or not SHA_RE.fullmatch(head_sha):
            fail(f"PR #{number} has an invalid head SHA")
        if not isinstance(base_ref, str) or not base_ref:
            fail(f"PR #{number} has an invalid base ref")

        draft = pr.get("draft")
        title = pr.get("title")
        if not isinstance(draft, bool):
            fail(f"PR #{number} has an invalid draft flag")
        if not isinstance(title, str):
            fail(f"PR #{number} has an invalid title")

        normalized.append(
            {
                "number": number,
                "head_ref": head_ref,
                "head_sha": head_sha,
                "base_ref": base_ref,
                "draft": draft,
                "title": " ".join(title.splitlines()),
            }
        )

    for item in normalized:
        print(json.dumps(item, ensure_ascii=False, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
