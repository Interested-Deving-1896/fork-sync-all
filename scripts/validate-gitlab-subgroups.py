#!/usr/bin/env python3
"""
validate-gitlab-subgroups.py

Validates config/gitlab-subgroups.yml for structural correctness and
consistency. Exits non-zero and prints actionable errors on any failure.

Checks:
  1. File is parseable by the same minimal parser used in the shell scripts
  2. Every subgroup has a numeric id and a non-empty repos list
  3. No repo name appears in more than one subgroup (collision check)
  4. default_subgroup references a subgroup that exists
  5. No repo name is empty or contains whitespace
  6. Subgroup names match the pattern used in GitLab paths (no spaces, no slashes)
  7. All namespace IDs are positive integers
  8. Round-trip: every repo resolves back to the expected subgroup via the
     same lookup logic the shell scripts use

Usage:
    python3 scripts/validate-gitlab-subgroups.py [path/to/gitlab-subgroups.yml]
    Defaults to config/gitlab-subgroups.yml relative to the script's repo root.
"""

import sys
import re
import os

# ── Parser (mirrors the logic in mirror-osp-to-gitlab.sh and reconcile-org-refs.sh) ──

def parse_config(path):
    """
    Returns:
        subgroups: dict[str, {"id": int, "repos": list[str]}]
        default_subgroup: str
    """
    with open(path) as f:
        content = f.read()

    subgroups = {}
    default_subgroup = None
    current_sg = None
    current_id = None

    for lineno, line in enumerate(content.splitlines(), 1):
        # default_subgroup: ops
        m = re.match(r'^default_subgroup:\s*(\S+)', line)
        if m:
            default_subgroup = m.group(1)
            continue

        # Top-level subgroup key (exactly 2-space indent)
        m = re.match(r'^  (\S+):$', line)
        if m:
            current_sg = m.group(1)
            current_id = None
            if current_sg not in subgroups:
                subgroups[current_sg] = {"id": None, "repos": []}
            continue

        # id: 130516402
        m = re.match(r'^\s+id:\s*(\d+)', line)
        if m and current_sg:
            current_id = int(m.group(1))
            subgroups[current_sg]["id"] = current_id
            continue

        # - repo-name
        m = re.match(r'^\s+-\s+(\S+)', line)
        if m and current_sg:
            subgroups[current_sg]["repos"].append(m.group(1))
            continue

    return subgroups, default_subgroup


def lookup(repo, subgroups, default_subgroup):
    """Same logic as gl_subgroup_lookup in the shell scripts."""
    for sg_name, sg in subgroups.items():
        if repo in sg["repos"]:
            return sg_name, sg["id"]
    # fallback
    if default_subgroup and default_subgroup in subgroups:
        sg = subgroups[default_subgroup]
        return default_subgroup, sg["id"]
    return "ops", 130734009


def validate(path):
    errors = []
    warnings = []

    # ── Parse ────────────────────────────────────────────────────────────────
    try:
        subgroups, default_subgroup = parse_config(path)
    except Exception as e:
        print(f"FATAL: could not parse {path}: {e}")
        sys.exit(1)

    if not subgroups:
        errors.append("No subgroups found — file may be empty or malformed")

    # ── Check 1: every subgroup has a numeric id ──────────────────────────────
    for sg_name, sg in subgroups.items():
        if sg["id"] is None:
            errors.append(f"Subgroup '{sg_name}' has no 'id' field")
        elif not isinstance(sg["id"], int) or sg["id"] <= 0:
            errors.append(f"Subgroup '{sg_name}' has invalid id: {sg['id']!r} (must be positive integer)")

    # ── Check 2: every subgroup has at least one repo ────────────────────────
    for sg_name, sg in subgroups.items():
        if not sg["repos"]:
            warnings.append(f"Subgroup '{sg_name}' has no repos listed")

    # ── Check 3: no repo name collision across subgroups ─────────────────────
    seen = {}  # repo_name → subgroup_name
    for sg_name, sg in subgroups.items():
        for repo in sg["repos"]:
            if repo in seen:
                errors.append(
                    f"Repo '{repo}' appears in both '{seen[repo]}' and '{sg_name}'"
                )
            else:
                seen[repo] = sg_name

    # ── Check 4: default_subgroup exists ─────────────────────────────────────
    if default_subgroup is None:
        errors.append("'default_subgroup' is not set")
    elif default_subgroup not in subgroups:
        errors.append(
            f"'default_subgroup: {default_subgroup}' references a subgroup that doesn't exist"
        )

    # ── Check 5: no empty or whitespace repo names ───────────────────────────
    for sg_name, sg in subgroups.items():
        for repo in sg["repos"]:
            if not repo or repo != repo.strip():
                errors.append(
                    f"Subgroup '{sg_name}' has invalid repo name: {repo!r}"
                )

    # ── Check 6: subgroup names are valid GitLab path segments ───────────────
    for sg_name in subgroups:
        if not re.match(r'^[a-zA-Z0-9_\-\.]+$', sg_name):
            errors.append(
                f"Subgroup name '{sg_name}' contains characters invalid in a GitLab path"
            )

    # ── Check 7: round-trip — every repo resolves to its own subgroup ────────
    for sg_name, sg in subgroups.items():
        for repo in sg["repos"]:
            resolved_sg, resolved_id = lookup(repo, subgroups, default_subgroup)
            if resolved_sg != sg_name:
                errors.append(
                    f"Round-trip failure: '{repo}' is in '{sg_name}' but lookup returns '{resolved_sg}'"
                )
            elif resolved_id != sg["id"]:
                errors.append(
                    f"Round-trip failure: '{repo}' id should be {sg['id']} but lookup returns {resolved_id}"
                )

    # ── Report ────────────────────────────────────────────────────────────────
    total_repos = sum(len(sg["repos"]) for sg in subgroups.values())
    print(f"config/gitlab-subgroups.yml: {len(subgroups)} subgroups, {total_repos} repos")

    for w in warnings:
        print(f"  WARNING: {w}")

    if errors:
        print(f"\n{len(errors)} error(s) found:")
        for e in errors:
            print(f"  ERROR: {e}")
        sys.exit(1)

    print("  ✅ Valid")
    sys.exit(0)


if __name__ == "__main__":
    if len(sys.argv) > 1:
        config_path = sys.argv[1]
    else:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        config_path = os.path.join(script_dir, "..", "config", "gitlab-subgroups.yml")

    config_path = os.path.normpath(config_path)

    if not os.path.exists(config_path):
        print(f"ERROR: {config_path} not found")
        sys.exit(1)

    validate(config_path)
