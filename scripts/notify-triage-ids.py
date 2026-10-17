#!/usr/bin/env python3
"""Print IDs for narrowly defined, non-actionable GitHub notifications.

The GitHub notifications endpoint is user-global. This helper therefore
requires both a managed repository owner and a known-safe title before a
thread is eligible for automatic triage.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any


DEFAULT_MANAGED_OWNERS = {
    "Interested-Deving-1896",
    "OpenOS-Project-OSP",
    "OpenOS-Project-Ecosystem-OOC",
}

# Exact workflow names whose notification noise is handled by the mirror/sync
# control plane. Exact matching avoids hiding unrelated workflows with generic
# names such as "CI", "Build", or "Checks".
SAFE_EXACT_TITLES = {
    "Mirror Interested-Deving-1896 → OSP",
    "Mirror to OpenOS-Project-OSP",
    "Mirror to OpenOS-Project-Ecosystem-OOC",
    "Sync btrfs-devel Branches",
    "btrfs-devel sync",
}

# Automated dependency updates and explicit quota artifacts are safe after the
# resolver pass. Keep this list narrow; every substring expands mutation scope.
SAFE_TITLE_SUBSTRINGS = (
    "dependabot",
    "chore(deps)",
    "chore: bump",
    "build(deps)",
    "fix(deps)",
    "quota exhausted",
    "rate limit exceeded",
    "api rate limit",
)


def managed_owners() -> set[str]:
    configured = os.environ.get("NOTIFICATION_OWNERS", "").split()
    return set(configured) if configured else DEFAULT_MANAGED_OWNERS


def is_known_safe(notification: dict[str, Any], owners: set[str]) -> bool:
    full_name = notification.get("repository", {}).get("full_name", "")
    owner, separator, _ = full_name.partition("/")
    if not separator or owner not in owners:
        return False

    title = notification.get("subject", {}).get("title", "")
    if title in SAFE_EXACT_TITLES:
        return True

    lowered = title.casefold()
    return any(pattern in lowered for pattern in SAFE_TITLE_SUBSTRINGS)


def main(argv: list[str]) -> int:
    notifs_file = Path(argv[1] if len(argv) > 1 else "/tmp/notifs.json")
    try:
        data = json.loads(notifs_file.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        print(f"error reading {notifs_file}: {exc}", file=sys.stderr)
        return 1

    if not isinstance(data, list):
        print(f"error reading {notifs_file}: expected a JSON list", file=sys.stderr)
        return 1

    owners = managed_owners()
    for notification in data:
        if not isinstance(notification, dict):
            continue
        notification_id = notification.get("id")
        if notification_id and is_known_safe(notification, owners):
            print(notification_id)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
