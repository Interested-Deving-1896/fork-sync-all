#!/usr/bin/env python3
"""
validate-registered-imports.py

Validates registered-imports.json against the schema expected by
scripts/sync-registered-imports.sh. Exits non-zero and prints actionable
errors on any failure.

Schema (array of objects):
  {
    "source_url":  string  — required, must be a valid https:// URL
    "target_name": string  — required, valid GitHub repo name (no slashes,
                             no spaces, 1-100 chars)
    "platform":    string  — required, one of: github, gitlab, bitbucket, gitea
    "added":       string  — required, ISO 8601 datetime (YYYY-MM-DDTHH:MM:SSZ)
  }

Additional checks:
  - No duplicate target_name values (would cause silent overwrites)
  - No duplicate source_url values (redundant syncs)
  - source_url host matches the declared platform
  - File is valid JSON (catches truncated writes mid-commit)
  - Empty file (0 bytes) is valid — treated as empty array

Usage:
    python3 scripts/validate-registered-imports.py [path/to/registered-imports.json]
    Defaults to registered-imports.json in the repo root.
"""

import sys
import re
import os
import json

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_PATH = os.path.join(REPO_ROOT, "registered-imports.json")

VALID_PLATFORMS = {"github", "gitlab", "bitbucket", "gitea"}

# Expected URL host substrings per platform
PLATFORM_HOSTS = {
    "github":    ["github.com"],
    "gitlab":    ["gitlab.com"],
    "bitbucket": ["bitbucket.org"],
    "gitea":     [],  # self-hosted — any host is valid
}

TARGET_NAME_RE = re.compile(r"^[a-zA-Z0-9._-]{1,100}$")
ISO8601_RE = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}"  # date + time
    r"(\.\d+)?"                                 # optional fractional seconds
    r"(Z|[+-]\d{2}:\d{2})$"                    # timezone
)

path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_PATH
errors = []


# ── Parse ─────────────────────────────────────────────────────────────────────

if not os.path.exists(path):
    print(f"ERROR: {path} not found")
    sys.exit(1)

raw = open(path).read().strip()

# Empty file is valid — treat as empty array
if not raw:
    print(f"validate-registered-imports: {path} is empty — nothing to validate (ok)")
    sys.exit(0)

try:
    data = json.loads(raw)
except json.JSONDecodeError as e:
    print(f"ERROR: {path} is not valid JSON: {e}")
    sys.exit(1)

if not isinstance(data, list):
    print(f"ERROR: {path} must be a JSON array, got {type(data).__name__}")
    sys.exit(1)

if len(data) == 0:
    print(f"validate-registered-imports: 0 entries — nothing to validate (ok)")
    sys.exit(0)


# ── Per-entry checks ──────────────────────────────────────────────────────────

seen_target_names = {}
seen_source_urls = {}

for i, entry in enumerate(data):
    prefix = f"entry[{i}]"

    if not isinstance(entry, dict):
        errors.append(f"{prefix}: must be an object, got {type(entry).__name__}")
        continue

    # Required fields
    for field in ("source_url", "target_name", "platform", "added"):
        if field not in entry:
            errors.append(f"{prefix}: missing required field '{field}'")
        elif not isinstance(entry[field], str):
            errors.append(f"{prefix}: '{field}' must be a string")
        elif not entry[field].strip():
            errors.append(f"{prefix}: '{field}' must not be empty")

    if errors:
        # Skip further checks for this entry if basics are missing
        continue

    source_url  = entry["source_url"].strip()
    target_name = entry["target_name"].strip()
    platform    = entry["platform"].strip()
    added       = entry["added"].strip()

    # source_url — must be https://
    if not source_url.startswith("https://"):
        errors.append(
            f"{prefix} ({target_name}): source_url must start with https://, "
            f"got '{source_url[:40]}'"
        )

    # platform — must be a known value
    if platform not in VALID_PLATFORMS:
        errors.append(
            f"{prefix} ({target_name}): platform '{platform}' is not valid. "
            f"Must be one of: {', '.join(sorted(VALID_PLATFORMS))}"
        )
    else:
        # source_url host must match platform (skip for gitea — self-hosted)
        expected_hosts = PLATFORM_HOSTS.get(platform, [])
        if expected_hosts and not any(h in source_url for h in expected_hosts):
            errors.append(
                f"{prefix} ({target_name}): platform is '{platform}' but "
                f"source_url '{source_url[:60]}' does not contain "
                f"{' or '.join(expected_hosts)}"
            )

    # target_name — valid GitHub repo name
    if not TARGET_NAME_RE.match(target_name):
        errors.append(
            f"{prefix}: target_name '{target_name}' is not a valid GitHub repo "
            f"name (1-100 chars, alphanumeric, hyphens, underscores, dots only)"
        )

    # added — ISO 8601
    if not ISO8601_RE.match(added):
        errors.append(
            f"{prefix} ({target_name}): 'added' value '{added}' is not a valid "
            f"ISO 8601 datetime (expected YYYY-MM-DDTHH:MM:SSZ)"
        )

    # Duplicate target_name
    if target_name in seen_target_names:
        errors.append(
            f"{prefix}: duplicate target_name '{target_name}' "
            f"(first seen at entry[{seen_target_names[target_name]}])"
        )
    else:
        seen_target_names[target_name] = i

    # Duplicate source_url
    if source_url in seen_source_urls:
        errors.append(
            f"{prefix} ({target_name}): duplicate source_url "
            f"(first seen at entry[{seen_source_urls[source_url]}])"
        )
    else:
        seen_source_urls[source_url] = i


# ── Report ────────────────────────────────────────────────────────────────────

if errors:
    print(f"validate-registered-imports: {len(errors)} error(s) in {path}\n")
    for err in errors:
        print(f"  ✗ {err}")
    sys.exit(1)
else:
    print(
        f"validate-registered-imports: {len(data)} entry/entries valid "
        f"({len(seen_target_names)} unique targets, {len(seen_source_urls)} unique sources)"
    )
