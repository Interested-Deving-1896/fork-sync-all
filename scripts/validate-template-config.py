#!/usr/bin/env python3
"""
validate-template-config.py

Validates config/template-manifest.yml and config/template-consumers.yml
against the schemas expected by scripts/sync-template.sh.

Checks for template-manifest.yml:
  - Valid YAML structure (profiles: top-level key)
  - Each profile has a description (string)
  - include/exclude lists contain only strings
  - No duplicate profile names
  - Glob patterns are non-empty strings (no structural validation — globs
    are too varied to validate without running them)

Checks for template-consumers.yml:
  - Valid YAML structure (consumers: top-level key, list of objects)
  - Each consumer has a required `name` field (non-empty string)
  - `name` is a valid GitHub repo name (1-100 chars, alphanumeric/hyphens/
    underscores/dots — same rule as registered-imports.py)
  - `profile` references a profile defined in template-manifest.yml
    (or is absent, which defaults to `full`)
  - `exclude_paths` and `include_paths` are lists of non-empty strings
  - `force`, `skip_osp_setup`, `disabled` are booleans if present
  - No duplicate consumer names
  - Cross-check: `full` profile must exist in manifest (it's the default)

Usage:
    python3 scripts/validate-template-config.py
    python3 scripts/validate-template-config.py \\
        [manifest-path] [consumers-path]
"""

import sys
import re
import os

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_MANIFEST  = os.path.join(REPO_ROOT, "config", "template-manifest.yml")
DEFAULT_CONSUMERS = os.path.join(REPO_ROOT, "config", "template-consumers.yml")

REPO_NAME_RE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,99}$")
BOOL_FIELDS  = {"force", "skip_osp_setup", "disabled"}
LIST_FIELDS  = {"exclude_paths", "include_paths"}
KNOWN_CONSUMER_FIELDS = {"name", "profile", "exclude_paths", "include_paths",
                         "force", "skip_osp_setup", "disabled"}

manifest_path  = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_MANIFEST
consumers_path = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_CONSUMERS

errors   = []
warnings = []


# ── Minimal YAML helpers ──────────────────────────────────────────────────────

def strip_comment(value):
    """Strip trailing inline YAML comment from a scalar."""
    if value.startswith(("'", '"')):
        return value.strip()
    m = re.match(r"^(.*?)(?:\s+#.*)?$", value.strip())
    return m.group(1).strip() if m else value.strip()


def parse_bool(value, field, prefix, errors):
    """Parse a YAML boolean scalar; append error on failure."""
    v = strip_comment(value).lower()
    if v in ("true", "yes", "on", "1"):
        return True
    if v in ("false", "no", "off", "0"):
        return False
    errors.append(f"{prefix}: '{field}' must be a boolean (true/false), got '{value}'")
    return None


# ── Parse template-manifest.yml ───────────────────────────────────────────────

def parse_manifest(path):
    """
    Returns a dict of {profile_name: {description, include, exclude}}.
    Appends to module-level `errors` list on any structural problem.
    """
    if not os.path.exists(path):
        errors.append(f"template-manifest.yml not found: {path}")
        return {}

    with open(path) as f:
        lines = f.readlines()

    profiles = {}
    in_profiles = False
    current_name = None
    current = {}
    current_list = None   # 'include' | 'exclude' | None
    in_description = False

    def flush():
        nonlocal current_name, current
        if current_name is not None:
            profiles[current_name] = current
        current_name = None
        current = {}

    for lineno, raw in enumerate(lines, 1):
        line = raw.rstrip()
        stripped = line.lstrip()
        indent = len(line) - len(stripped)

        if not stripped or stripped.startswith("#"):
            continue

        # Top-level `profiles:` key
        if re.match(r"^profiles\s*:", line):
            in_profiles = True
            continue

        # Any other top-level key ends profiles section
        if re.match(r"^[a-zA-Z]", line) and not line.startswith(" "):
            flush()
            in_profiles = False
            continue

        if not in_profiles:
            continue

        # Profile name: 2-space indent, ends with colon
        if indent == 2 and re.match(r"^  [a-zA-Z0-9][a-zA-Z0-9_-]*:\s*$", line):
            flush()
            current_name = stripped.rstrip(":")
            current = {"_lineno": lineno, "include": [], "exclude": []}
            current_list = None
            in_description = False
            continue

        if current_name is None:
            continue

        # 4-space indent: field key
        if indent == 4:
            in_description = False
            current_list = None
            m = re.match(r"^    (description|include|exclude)\s*:(.*)", line)
            if m:
                key = m.group(1)
                val = strip_comment(m.group(2).strip())
                if key == "description":
                    if val in (">", "|", ">-", "|-", ""):
                        current["description"] = ""
                        in_description = True
                    else:
                        current["description"] = val
                elif key in ("include", "exclude"):
                    current_list = key
            continue

        # 6-space indent: list item or description continuation
        if indent == 6 and current_name:
            if in_description:
                current["description"] = current.get("description", "") + " " + stripped
            elif current_list and stripped.startswith("- "):
                current[current_list].append(stripped[2:].strip())
            continue

        # 8-space indent: description block continuation
        if indent >= 6 and in_description:
            current["description"] = current.get("description", "") + " " + stripped

    flush()
    return profiles


# ── Parse template-consumers.yml ─────────────────────────────────────────────

def parse_consumers(path):
    """
    Returns a list of consumer dicts.
    Appends to module-level `errors` list on any structural problem.
    """
    if not os.path.exists(path):
        errors.append(f"template-consumers.yml not found: {path}")
        return []

    with open(path) as f:
        lines = f.readlines()

    consumers = []
    in_consumers = False
    current = None
    current_list = None  # 'exclude_paths' | 'include_paths' | None

    def flush():
        nonlocal current
        if current is not None:
            consumers.append(current)
        current = None

    for lineno, raw in enumerate(lines, 1):
        line = raw.rstrip()
        stripped = line.lstrip()
        indent = len(line) - len(stripped)

        if not stripped or stripped.startswith("#"):
            continue

        # Top-level `consumers:` key
        if re.match(r"^consumers\s*:", line):
            in_consumers = True
            continue

        # Any other top-level key ends consumers section
        if re.match(r"^[a-zA-Z]", line) and not line.startswith(" "):
            flush()
            in_consumers = False
            continue

        if not in_consumers:
            continue

        # New consumer entry: `  - name: ...` or `  - ` (start of entry)
        m = re.match(r"^  - name:\s*(.+)", line)
        if m:
            flush()
            current = {"_lineno": lineno, "name": strip_comment(m.group(1))}
            current_list = None
            continue

        m = re.match(r"^  - $", line)
        if m:
            flush()
            current = {"_lineno": lineno}
            current_list = None
            continue

        if current is None:
            continue

        # 4-space indent: field
        if indent == 4:
            current_list = None
            m = re.match(r"^    ([a-zA-Z_]+):\s*(.*)", line)
            if m:
                key = m.group(1)
                val = strip_comment(m.group(2).strip())
                if key in LIST_FIELDS:
                    if val in ("[", ""):
                        current[key] = []
                        current_list = key
                    elif val.startswith("[") and val.endswith("]"):
                        # Inline list: [a, b, c]
                        items = [x.strip().strip('"').strip("'")
                                 for x in val[1:-1].split(",") if x.strip()]
                        current[key] = items
                    else:
                        current[key] = []
                        current_list = key
                elif key in BOOL_FIELDS:
                    current[key] = val
                else:
                    current[key] = val
            continue

        # 6-space indent: list item
        if indent == 6 and current_list and stripped.startswith("- "):
            current.setdefault(current_list, []).append(stripped[2:].strip())
            continue

    flush()
    return consumers


# ── Validate manifest ─────────────────────────────────────────────────────────

profiles = parse_manifest(manifest_path)

seen_profile_names = {}
for name, prof in profiles.items():
    lineno = prof.get("_lineno", "?")
    prefix = f"manifest profile '{name}' (line {lineno})"

    # Duplicate name
    if name in seen_profile_names:
        errors.append(f"{prefix}: duplicate profile name (first at line {seen_profile_names[name]})")
    else:
        seen_profile_names[name] = lineno

    # description — required, non-empty
    desc = prof.get("description", "").strip()
    if not desc:
        errors.append(f"{prefix}: missing or empty 'description'")

    # include/exclude — lists of non-empty strings
    for field in ("include", "exclude"):
        for i, pat in enumerate(prof.get(field, [])):
            if not isinstance(pat, str) or not pat.strip():
                errors.append(f"{prefix}: {field}[{i}] must be a non-empty string, got '{pat}'")

# `full` profile must exist — it's the implicit default for consumers
if profiles and "full" not in profiles:
    errors.append(
        "template-manifest.yml: 'full' profile is missing — it is the implicit "
        "default for consumers that don't specify a profile"
    )


# ── Validate consumers ────────────────────────────────────────────────────────

consumers = parse_consumers(consumers_path)

seen_consumer_names = {}
for consumer in consumers:
    lineno = consumer.get("_lineno", "?")

    # name — required
    name = consumer.get("name", "").strip()
    if not name:
        errors.append(f"consumers (line {lineno}): missing required field 'name'")
        continue

    prefix = f"consumer '{name}' (line {lineno})"

    # Duplicate name
    if name in seen_consumer_names:
        errors.append(
            f"{prefix}: duplicate consumer name "
            f"(first seen at line {seen_consumer_names[name]})"
        )
    else:
        seen_consumer_names[name] = lineno

    # name format — valid GitHub repo name
    if not REPO_NAME_RE.match(name):
        errors.append(
            f"{prefix}: not a valid GitHub repo name "
            f"(1-100 chars, alphanumeric/hyphens/underscores/dots)"
        )

    # profile — must reference a known profile (or be absent → defaults to full)
    profile = consumer.get("profile", "full").strip()
    if profiles and profile not in profiles:
        errors.append(
            f"{prefix}: profile '{profile}' is not defined in template-manifest.yml. "
            f"Known profiles: {', '.join(sorted(profiles.keys()))}"
        )

    # exclude_paths / include_paths — lists of non-empty strings
    for field in ("exclude_paths", "include_paths"):
        val = consumer.get(field)
        if val is None:
            continue
        if not isinstance(val, list):
            errors.append(f"{prefix}: '{field}' must be a list")
            continue
        for i, pat in enumerate(val):
            if not isinstance(pat, str) or not pat.strip():
                errors.append(f"{prefix}: {field}[{i}] must be a non-empty string, got '{pat}'")

    # boolean fields
    for field in BOOL_FIELDS:
        if field in consumer:
            parse_bool(consumer[field], field, prefix, errors)

    # unknown fields
    for field in consumer:
        if field not in KNOWN_CONSUMER_FIELDS and not field.startswith("_"):
            warnings.append(f"{prefix}: unknown field '{field}'")


# ── Report ────────────────────────────────────────────────────────────────────

if warnings:
    for w in warnings:
        print(f"  ⚠ {w}")

if errors:
    print(f"\nvalidate-template-config: {len(errors)} error(s)\n")
    for err in errors:
        print(f"  ✗ {err}")
    sys.exit(1)
else:
    print(
        f"validate-template-config: "
        f"{len(profiles)} profile(s) valid, "
        f"{len(consumers)} consumer(s) valid"
    )
