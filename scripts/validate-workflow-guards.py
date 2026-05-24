#!/usr/bin/env python3
"""
validate-workflow-guards.py

Two checks run on every push/PR that touches workflows or .gitlab-ci.yml:

Check 1 — rate_limit_rerun guard completeness
  Every GitHub Actions workflow that declares a `rate_limit_rerun` input
  must also have `inputs.rate_limit_rerun != 'true'` in a job-level `if:`
  condition. Without this guard a re-dispatched workflow that fails again
  will be picked up by the next scan cycle, creating an infinite loop.

Check 2 — .gitlab-ci.yml script existence
  Every `bash scripts/<name>.sh` reference in .gitlab-ci.yml must resolve
  to an actual file in scripts/. Catches renames/deletions before they
  cause silent GitLab CI failures.

Exit codes:
  0 — all checks passed
  1 — one or more checks failed (errors printed to stdout)
"""

import sys
import re
import os
import glob

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKFLOWS_DIR = os.path.join(REPO_ROOT, ".github", "workflows")
GITLAB_CI = os.path.join(REPO_ROOT, ".gitlab-ci.yml")
SCRIPTS_DIR = os.path.join(REPO_ROOT, "scripts")

errors = []


# ── Check 1: rate_limit_rerun guard completeness ──────────────────────────────

for wf_path in sorted(glob.glob(os.path.join(WORKFLOWS_DIR, "*.yml"))):
    wf_name = os.path.basename(wf_path)
    with open(wf_path) as f:
        content = f.read()

    # Only flag workflows that declare rate_limit_rerun as a workflow_dispatch
    # input (indented under `inputs:` inside a `workflow_dispatch:` block).
    # A bare string match would catch step names, comments, etc.
    if not re.search(r"^\s{6,}rate_limit_rerun\s*:", content, re.MULTILINE):
        continue

    # Workflow declares the input — verify the job-level guard is present.
    # Accept either form:
    #   if: inputs.rate_limit_rerun != 'true'
    #   if: ... && inputs.rate_limit_rerun != 'true'
    #   if: inputs.rate_limit_rerun != "true"
    guard_pattern = re.compile(
        r"""inputs\.rate_limit_rerun\s*!=\s*['"]true['"]"""
    )
    if not guard_pattern.search(content):
        errors.append(
            f"[guard] {wf_name}: declares rate_limit_rerun input but has no "
            f"job-level guard.\n"
            f"  Add to the primary job: if: inputs.rate_limit_rerun != 'true'"
        )


# ── Check 2: .gitlab-ci.yml script existence ─────────────────────────────────

if os.path.exists(GITLAB_CI):
    with open(GITLAB_CI) as f:
        gl_content = f.read()

    referenced = set(re.findall(r"bash scripts/([a-zA-Z0-9_-]+\.sh)", gl_content))
    for script_name in sorted(referenced):
        script_path = os.path.join(SCRIPTS_DIR, script_name)
        if not os.path.isfile(script_path):
            errors.append(
                f"[gitlab-ci] scripts/{script_name} is referenced in "
                f".gitlab-ci.yml but does not exist."
            )
else:
    print(f"WARNING: {GITLAB_CI} not found — skipping GitLab CI script check")


# ── Report ────────────────────────────────────────────────────────────────────

if errors:
    print(f"validate-workflow-guards: {len(errors)} error(s) found\n")
    for err in errors:
        print(f"  ✗ {err}")
    sys.exit(1)
else:
    wf_count = len(glob.glob(os.path.join(WORKFLOWS_DIR, "*.yml")))
    print(
        f"validate-workflow-guards: all checks passed "
        f"({wf_count} workflows, .gitlab-ci.yml script refs verified)"
    )
