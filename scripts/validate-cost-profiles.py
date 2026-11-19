#!/usr/bin/env python3
"""
validate-cost-profiles.py

Validates config/workflow-cost-profiles.yml against the schema expected by
the rate-limit profiler. Exits non-zero and prints actionable errors on any
failure.

Schema (under `profiles:`):
  <profile-name>:
    rest_calls:           int >= 0   required
    graphql_calls:        int >= 0   required
    gitlab_calls:         int >= 0   required
    ai_calls:             int >= 0   required
    scales_with:          str|null   required  (variable name or null/~)
    scale_factor:         int >= 0   required
    minimum_rest_budget:  int >= 0   required
    notes:                str        optional

Optional fields (added by rate-limit-learn.sh after observed runs):
    actual_rest_calls:    int >= 0
    actual_duration_s:    int >= 0
    rest_cost:            int >= 0
    graphql_cost:         int >= 0
    graphql_query:        str

Additional checks:
  - No duplicate profile names
  - scale_factor must be 0 when scales_with is null/~
  - minimum_rest_budget must be >= rest_calls (budget must cover base cost)
  - Profile names must be valid identifiers (alphanumeric, hyphens, underscores)

Usage:
    python3 scripts/validate-cost-profiles.py [path/to/workflow-cost-profiles.yml]
    Defaults to config/workflow-cost-profiles.yml in the repo root.
"""

import sys
import re
import os

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_PATH = os.path.join(REPO_ROOT, "config", "workflow-cost-profiles.yml")

REQUIRED_INT_FIELDS = [
    "rest_calls",
    "graphql_calls",
    "gitlab_calls",
    "ai_calls",
    "scale_factor",
    "minimum_rest_budget",
]

OPTIONAL_INT_FIELDS = [
    "actual_rest_calls",
    "actual_duration_s",
    "rest_cost",
    "graphql_cost",
]

OPTIONAL_STR_FIELDS = [
    "graphql_query",
    "notes",
]

PROFILE_NAME_RE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9_-]*$")

path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_PATH
errors = []


# ── Parse ─────────────────────────────────────────────────────────────────────

if not os.path.exists(path):
    print(f"ERROR: {path} not found")
    sys.exit(1)

with open(path) as f:
    lines = f.readlines()

# Minimal YAML parser — extracts profiles without a PyYAML dependency.
# Handles the specific structure of workflow-cost-profiles.yml.

def strip_inline_comment(value):
    """Strip trailing inline YAML comment from a scalar value."""
    # Don't strip from quoted strings
    if value.startswith(("'", '"')):
        return value.strip()
    m = re.match(r"^(.*?)(?:\s+#.*)?$", value.strip())
    return m.group(1).strip() if m else value.strip()


profiles = {}       # name -> dict of fields
current_profile = None
current_fields = {}
in_profiles = False
in_notes = False    # multi-line block scalar
skip_section = False  # True when current 2-space block is a list, not a profile

for lineno, raw in enumerate(lines, 1):
    line = raw.rstrip()
    stripped = line.lstrip()
    indent = len(line) - len(stripped)

    if not stripped or stripped.startswith("#"):
        continue

    # Top-level `profiles:` key
    if re.match(r"^profiles\s*:", line):
        in_profiles = True
        skip_section = False
        continue

    # Any other top-level key ends the profiles section
    if re.match(r"^[a-zA-Z]", line) and not line.startswith(" "):
        in_profiles = False
        skip_section = False
        continue

    if not in_profiles:
        continue

    # Profile name (2-space indent, ends with colon, not a list item)
    m = re.match(r"^  ([a-zA-Z0-9][a-zA-Z0-9_-]*):\s*$", line)
    if m:
        # Peek ahead to determine if this is a profile (key-value children)
        # or a list section (list-item children). List sections are written
        # by rate-limit-learn.sh and are not profiles.
        name_candidate = m.group(1)
        peek_lineno = lineno  # current line index in `lines` (0-based: lineno-1)
        is_list_section = False
        for peek_raw in lines[lineno:]:  # lines after current
            peek = peek_raw.rstrip()
            peek_stripped = peek.lstrip()
            if not peek_stripped or peek_stripped.startswith("#"):
                continue
            peek_indent = len(peek) - len(peek_stripped)
            if peek_indent <= 2:
                break  # next sibling or parent — stop
            if peek_stripped.startswith("- "):
                is_list_section = True
            break

        if is_list_section:
            skip_section = True
            if current_profile:
                profiles[current_profile] = current_fields
            current_profile = None
            current_fields = {}
            continue

        skip_section = False
        if current_profile:
            profiles[current_profile] = current_fields
        current_profile = name_candidate
        current_fields = {"_lineno": lineno}
        in_notes = False
        continue

    if skip_section:
        continue

    # Field (4-space indent)
    if indent == 4 and current_profile:
        in_notes = False
        m = re.match(r"^    ([a-zA-Z_]+):\s*(.*)", line)
        if m:
            key = m.group(1)
            val = strip_inline_comment(m.group(2))
            # Block scalar (notes: >) — value is on subsequent lines
            if val in (">", "|", ">-", "|-"):
                current_fields[key] = ""
                in_notes = True
            else:
                current_fields[key] = val
        continue

    # Continuation of block scalar (6+ space indent)
    if indent >= 6 and in_notes and current_profile:
        key = [k for k in current_fields if k not in REQUIRED_INT_FIELDS + OPTIONAL_INT_FIELDS + OPTIONAL_STR_FIELDS + ["scales_with", "_lineno"] or k == "notes" or k == "graphql_query"]
        # Append to the last string field
        for k in ("notes", "graphql_query"):
            if k in current_fields and isinstance(current_fields[k], str):
                current_fields[k] += " " + stripped
                break
        continue

# Flush last profile
if current_profile:
    profiles[current_profile] = current_fields

if not profiles:
    print(f"ERROR: no profiles found in {path} — check file structure")
    sys.exit(1)


# ── Per-profile checks ────────────────────────────────────────────────────────

seen_names = {}

for name, fields in profiles.items():
    lineno = fields.get("_lineno", "?")
    prefix = f"profile '{name}' (line {lineno})"

    # Duplicate name check
    if name in seen_names:
        errors.append(f"{prefix}: duplicate profile name (first seen at line {seen_names[name]})")
    else:
        seen_names[name] = lineno

    # Profile name format
    if not PROFILE_NAME_RE.match(name):
        errors.append(f"{prefix}: invalid profile name — use alphanumeric, hyphens, underscores only")

    # Required integer fields
    for field in REQUIRED_INT_FIELDS:
        if field not in fields:
            errors.append(f"{prefix}: missing required field '{field}'")
            continue
        val = fields[field]
        try:
            ival = int(val)
            if ival < 0:
                errors.append(f"{prefix}: '{field}' must be >= 0, got {ival}")
        except (ValueError, TypeError):
            errors.append(f"{prefix}: '{field}' must be an integer, got '{val}'")

    # scales_with — required, must be a string or null
    if "scales_with" not in fields:
        errors.append(f"{prefix}: missing required field 'scales_with'")
    else:
        sw = fields["scales_with"]
        is_null = sw in ("null", "~", "")
        if not is_null and not re.match(r"^[a-zA-Z_][a-zA-Z0-9_]*$", sw):
            errors.append(
                f"{prefix}: 'scales_with' must be a variable name or null, got '{sw}'"
            )

        # scale_factor must be 0 when scales_with is null
        if is_null and "scale_factor" in fields:
            try:
                sf = int(fields["scale_factor"])
                if sf != 0:
                    errors.append(
                        f"{prefix}: 'scale_factor' must be 0 when 'scales_with' is null, got {sf}"
                    )
            except (ValueError, TypeError):
                pass  # already caught above

    # minimum_rest_budget must cover base rest_calls
    if "minimum_rest_budget" in fields and "rest_calls" in fields:
        try:
            budget = int(fields["minimum_rest_budget"])
            base = int(fields["rest_calls"])
            if budget < base:
                errors.append(
                    f"{prefix}: 'minimum_rest_budget' ({budget}) is less than "
                    f"'rest_calls' ({base}) — budget must cover at least the base cost"
                )
        except (ValueError, TypeError):
            pass  # already caught above

    # Optional integer fields — validate type if present
    for field in OPTIONAL_INT_FIELDS:
        if field in fields:
            val = fields[field]
            try:
                ival = int(val)
                if ival < 0:
                    errors.append(f"{prefix}: '{field}' must be >= 0, got {ival}")
            except (ValueError, TypeError):
                errors.append(f"{prefix}: '{field}' must be an integer, got '{val}'")

    # Warn on unknown fields (not an error — rate-limit-learn.sh may add new ones)
    known = set(REQUIRED_INT_FIELDS + OPTIONAL_INT_FIELDS + OPTIONAL_STR_FIELDS + ["scales_with", "_lineno"])
    for field in fields:
        if field not in known:
            print(f"  ⚠ {prefix}: unknown field '{field}' (may be added by rate-limit-learn.sh)")


# ── Report ────────────────────────────────────────────────────────────────────

if errors:
    print(f"validate-cost-profiles: {len(errors)} error(s) in {path}\n")
    for err in errors:
        print(f"  ✗ {err}")
    sys.exit(1)
else:
    print(
        f"validate-cost-profiles: {len(profiles)} profile(s) valid in {path}"
    )
