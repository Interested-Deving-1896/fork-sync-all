#!/usr/bin/env python3
"""
generate-gitlab-stubs.py

Reads config/workflow-sync.yml and produces a unified diff showing what
would need to change in .gitlab-ci.yml to bring paired jobs into sync with
their GitHub Actions counterparts.

Scope is intentionally narrow — it only checks fields that are machine-
verifiable from the manifest:
  - The script(s) called by each paired job
  - The CADENCE rule that activates the job

It does NOT attempt to regenerate full job blocks (image, before_script,
timeout, env vars) because those often have platform-specific values that
the manifest doesn't encode. The diff is for human review, not auto-apply.

Usage:
    python3 scripts/generate-gitlab-stubs.py [--check]

    --check   Exit non-zero if any drift is detected (for CI use).
              Without --check, always exits 0 (informational output only).

Output:
    Prints a summary of paired jobs and any detected drift to stdout.
    If --check is passed and drift exists, exits 1.
"""

import sys
import re
import os
import difflib

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GITLAB_CI = os.path.join(REPO_ROOT, ".gitlab-ci.yml")
SYNC_MANIFEST = os.path.join(REPO_ROOT, "config", "workflow-sync.yml")

CHECK_MODE = "--check" in sys.argv


def _strip_comment(value):
    """Strip trailing inline YAML comment and whitespace from a scalar value."""
    # Split on first ' #' that isn't inside quotes
    m = re.match(r"^([^#'\"]*?)(?:\s+#.*)?$", value.strip())
    return m.group(1).strip() if m else value.strip()


# ── Manifest parser (same logic as validate-workflow-guards.py) ───────────────

def parse_sync_manifest(path):
    with open(path) as f:
        lines = f.readlines()

    paired = []
    section = None
    current = {}
    sub = None

    def flush():
        nonlocal current
        if current:
            paired.append(current)
        current = {}

    for raw in lines:
        line = raw.rstrip()
        stripped = line.lstrip()
        indent = len(line) - len(stripped)

        if not stripped or stripped.startswith("#"):
            continue

        if re.match(r"^paired\s*:", line):
            flush()
            section = "paired"
            sub = None
            continue
        if re.match(r"^(github_only|gitlab_only)\s*:", line):
            flush()
            section = None
            continue

        if section != "paired":
            continue

        if re.match(r"^  - ", line):
            flush()
            current = {"scripts": [], "github": {}, "gitlab": {}, "env_vars": []}
            sub = None
            m = re.match(r"^  - name:\s*(.+)", line)
            if m:
                current["name"] = m.group(1).strip()
            continue

        if indent == 4:
            if re.match(r"    scripts\s*:", line):
                sub = "scripts"
            elif re.match(r"    github\s*:", line):
                sub = "github"
            elif re.match(r"    gitlab\s*:", line):
                sub = "gitlab"
            elif re.match(r"    env_vars\s*:", line):
                sub = "env_vars"
            else:
                sub = None

        if indent == 6:
            if sub == "scripts":
                m = re.match(r"      - ([a-zA-Z0-9_-]+\.sh)", line)
                if m:
                    current["scripts"].append(m.group(1))
            elif sub == "github":
                m = re.match(r"      workflow_file:\s*(.+)", line)
                if m:
                    current["github"]["workflow_file"] = m.group(1).strip()
                m = re.match(r"      schedule:\s*(.+)", line)
                if m:
                    current["github"]["schedule"] = m.group(1).strip().strip("\"'")
            elif sub == "gitlab":
                m = re.match(r"      job:\s*(.+)", line)
                if m:
                    current["gitlab"]["job"] = _strip_comment(m.group(1))
                m = re.match(r"      cadence:\s*(.+)", line)
                if m:
                    current["gitlab"]["cadence"] = _strip_comment(m.group(1))
                m = re.match(r"      script:\s*(.+)", line)
                if m:
                    current["gitlab"]["script"] = _strip_comment(m.group(1))
            elif sub == "env_vars":
                m = re.match(r"      - ([A-Z_]+)", line)
                if m:
                    current["env_vars"].append(m.group(1))

    flush()
    return paired


# ── GitLab CI job block extractor ─────────────────────────────────────────────

def extract_job_block(gl_content, job_name):
    """
    Returns the lines of the named job block (from job_name: to the next
    top-level key), or None if the job is not found.
    """
    lines = gl_content.splitlines(keepends=True)
    start = None
    end = None

    job_header = re.compile(r"^" + re.escape(job_name) + r"\s*:\s*$")
    top_level = re.compile(r"^[a-zA-Z]")

    for i, line in enumerate(lines):
        if start is None:
            if job_header.match(line):
                start = i
        else:
            # Next top-level key (not a comment, not blank) ends the block
            if top_level.match(line) and not line.startswith("#"):
                end = i
                break

    if start is None:
        return None
    if end is None:
        end = len(lines)

    return lines[start:end]


def job_scripts(block_lines):
    """Extract `bash scripts/foo.sh` calls from a job block."""
    scripts = []
    for line in block_lines:
        for m in re.finditer(r"bash scripts/([a-zA-Z0-9_-]+\.sh)", line):
            scripts.append(m.group(1))
    return list(dict.fromkeys(scripts))  # dedupe, preserve order


def job_cadence(block_lines):
    """Extract CADENCE value from rules: block, or None."""
    for line in block_lines:
        m = re.search(r'CADENCE\s*==\s*["\'](\w+)["\']', line)
        if m:
            return m.group(1)
    return None


def job_push_trigger(block_lines):
    """Return True if job has a push-based rule."""
    for line in block_lines:
        if 'CI_PIPELINE_SOURCE == "push"' in line or "CI_PIPELINE_SOURCE == 'push'" in line:
            return True
    return False


# ── Drift detection ───────────────────────────────────────────────────────────

def job_trigger_rule(block_lines):
    """Return True if job has a CI_PIPELINE_SOURCE == 'trigger' rule."""
    for line in block_lines:
        if 'CI_PIPELINE_SOURCE == "trigger"' in line or "CI_PIPELINE_SOURCE == 'trigger'" in line:
            return True
    return False


def detect_drift(entry, block_lines):
    """
    Returns a list of (field, expected, actual) drift tuples.
    """
    drift = []
    gl_info = entry.get("gitlab", {})
    expected_cadence = gl_info.get("cadence", "")
    # gitlab.script overrides the shared scripts list for the GitLab side.
    # Use it when the GL job uses a wrapper script rather than calling the
    # shared script directly (e.g. sync-forks.sh wraps sync-all-forks.sh).
    gl_script_override = gl_info.get("script")
    expected_scripts = (
        [gl_script_override] if gl_script_override
        else entry.get("scripts", [])
    )

    # Script check: every expected script should appear in the job block.
    actual_scripts = job_scripts(block_lines)
    for script in expected_scripts:
        if script not in actual_scripts:
            drift.append(("script", script, f"not found (actual: {actual_scripts})"))

    # Cadence / trigger check
    if expected_cadence == "push":
        if not job_push_trigger(block_lines):
            drift.append(("trigger", "push", "not found"))
    elif expected_cadence == "trigger":
        if not job_trigger_rule(block_lines):
            drift.append(("trigger", "CI_PIPELINE_SOURCE==trigger", "not found"))
    elif expected_cadence and expected_cadence != "manual":
        actual_cadence = job_cadence(block_lines)
        if actual_cadence != expected_cadence:
            drift.append(("cadence", expected_cadence, actual_cadence or "none"))

    return drift


# ── Main ──────────────────────────────────────────────────────────────────────

if not os.path.exists(SYNC_MANIFEST):
    print(f"ERROR: {SYNC_MANIFEST} not found")
    sys.exit(1)

if not os.path.exists(GITLAB_CI):
    print(f"ERROR: {GITLAB_CI} not found")
    sys.exit(1)

with open(GITLAB_CI) as f:
    gl_content = f.read()

paired = parse_sync_manifest(SYNC_MANIFEST)

drift_found = False
ok_count = 0
drift_count = 0
missing_count = 0

print(f"Checking {len(paired)} paired jobs from config/workflow-sync.yml\n")
print(f"{'Job':<35} {'Status'}")
print(f"{'-'*35} {'-'*40}")

all_drift_details = []

for entry in paired:
    gl_job = entry.get("gitlab", {}).get("job", "")
    name = entry.get("name", gl_job)

    if not gl_job:
        continue

    block = extract_job_block(gl_content, gl_job)
    if block is None:
        print(f"  {gl_job:<33} ✗ job not found in .gitlab-ci.yml")
        missing_count += 1
        drift_found = True
        continue

    drift = detect_drift(entry, block)
    if drift:
        print(f"  {gl_job:<33} ⚠ drift detected")
        for field, expected, actual in drift:
            detail = f"    [{gl_job}] {field}: expected '{expected}', got '{actual}'"
            print(detail)
            all_drift_details.append((gl_job, field, expected, actual))
        drift_count += 1
        drift_found = True
    else:
        print(f"  {gl_job:<33} ✓")
        ok_count += 1

print(f"\nSummary: {ok_count} ok, {drift_count} drifted, {missing_count} missing")

if drift_found:
    print(
        "\nNote: this script reports drift for human review — it does not auto-apply changes.\n"
        "Edit .gitlab-ci.yml manually to resolve, then re-run to confirm."
    )
    if CHECK_MODE:
        sys.exit(1)
else:
    print("\n.gitlab-ci.yml paired jobs are in sync with config/workflow-sync.yml")
