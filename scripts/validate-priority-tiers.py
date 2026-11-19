#!/usr/bin/env python3
"""
validate-priority-tiers.py

Validates config/workflow-priority-tiers.yml.

Checks:
  - Valid YAML (safe_load)
  - Each entry has 'name' (non-empty string) and 'tier' (int 1-4)
  - No duplicate names
  - default_tier is present and is 1-4

Usage:
    python3 scripts/validate-priority-tiers.py [path/to/workflow-priority-tiers.yml]
"""

import sys
import os
import yaml

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_PATH = os.path.join(REPO_ROOT, "config", "workflow-priority-tiers.yml")

path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_PATH
errors = []

if not os.path.exists(path):
    print(f"ERROR: {path} not found")
    sys.exit(1)

with open(path) as f:
    try:
        data = yaml.safe_load(f)
    except yaml.YAMLError as e:
        print(f"ERROR: YAML parse error in {path}: {e}")
        sys.exit(1)

if not isinstance(data, dict):
    print(f"ERROR: {path} must be a YAML mapping at the top level")
    sys.exit(1)

# default_tier
default_tier = data.get("default_tier")
if default_tier is None:
    errors.append("missing required field 'default_tier'")
elif not isinstance(default_tier, int) or default_tier not in (1, 2, 3, 4):
    errors.append(f"'default_tier' must be an integer 1-4, got {default_tier!r}")

# tiers list
tiers = data.get("tiers")
if not tiers:
    errors.append("missing or empty 'tiers' list")
elif not isinstance(tiers, list):
    errors.append("'tiers' must be a list")
else:
    seen_names = {}
    for i, entry in enumerate(tiers):
        pos = f"entry {i+1}"
        if not isinstance(entry, dict):
            errors.append(f"{pos}: must be a mapping with 'name' and 'tier'")
            continue

        name = entry.get("name")
        tier = entry.get("tier")

        if not name or not isinstance(name, str):
            errors.append(f"{pos}: 'name' must be a non-empty string, got {name!r}")
        else:
            if name in seen_names:
                errors.append(f"{pos}: duplicate name '{name}' (first seen at entry {seen_names[name]})")
            else:
                seen_names[name] = i + 1

        if tier is None:
            errors.append(f"{pos} ('{name}'): missing required field 'tier'")
        elif not isinstance(tier, int) or tier not in (1, 2, 3, 4):
            errors.append(f"{pos} ('{name}'): 'tier' must be an integer 1-4, got {tier!r}")

if errors:
    print(f"validate-priority-tiers: {len(errors)} error(s) in {path}\n")
    for err in errors:
        print(f"  ✗ {err}")
    sys.exit(1)
else:
    tier_counts = {t: sum(1 for e in tiers if e.get("tier") == t) for t in range(1, 5)}
    print(
        f"validate-priority-tiers: {len(tiers)} entries valid in {path} "
        f"(tier1={tier_counts[1]}, tier2={tier_counts[2]}, "
        f"tier3={tier_counts[3]}, tier4={tier_counts[4]})"
    )
