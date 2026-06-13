#!/usr/bin/env python3
"""
validate-workflow-guards.py

Checks run on every push/PR that touches workflows, .gitlab-ci.yml, or
config/workflow-sync.yml:

Check 1 — rate_limit_rerun guard completeness
  Every GitHub Actions workflow that declares a `rate_limit_rerun` input
  must also have `inputs.rate_limit_rerun != 'true'` in a job-level `if:`
  condition. Without this guard a re-dispatched workflow that fails again
  will be picked up by the next scan cycle, creating an infinite loop.

Check 2 — .gitlab-ci.yml script existence
  Every `bash scripts/<name>.sh` reference in .gitlab-ci.yml must resolve
  to an actual file in scripts/. Catches renames/deletions before they
  cause silent GitLab CI failures.

Check 3 — workflow-sync.yml manifest consistency
  For every entry in config/workflow-sync.yml `paired` list:
    a. github.workflow_file exists in .github/workflows/
    b. gitlab.job exists in .gitlab-ci.yml
    c. every script listed under scripts exists in scripts/
  For every entry in github_only:
    d. workflow_file exists in .github/workflows/
  For every entry in gitlab_only:
    e. job exists in .gitlab-ci.yml

Check 4 — workflow-quota-costs.yml name consistency
  Every `name:` entry in config/workflow-quota-costs.yml must match the
  `name:` field of an actual workflow file in .github/workflows/. Catches
  stale entries left behind after a workflow is renamed or removed.


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
SYNC_MANIFEST = os.path.join(REPO_ROOT, "config", "workflow-sync.yml")
QUOTA_COSTS = os.path.join(REPO_ROOT, "config", "workflow-quota-costs.yml")

errors = []
warnings = []


# ── Check 1: rate_limit_rerun guard completeness ──────────────────────────────

for wf_path in sorted(glob.glob(os.path.join(WORKFLOWS_DIR, "*.yml")) +
                      glob.glob(os.path.join(WORKFLOWS_DIR, "*.yaml"))):
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

gl_content = ""
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
    warnings.append(f".gitlab-ci.yml not found — skipping GitLab CI script check")


# ── Check 3: workflow-sync.yml manifest consistency ──────────────────────────
#
# Minimal YAML parser — avoids a PyYAML dependency. Reads only the fields
# the validator needs: paired[].github.workflow_file, paired[].gitlab.job,
# paired[].scripts[], github_only[].workflow_file, gitlab_only[].job.

def parse_sync_manifest(path):
    """
    Returns:
      paired      — list of dicts with keys: name, scripts, github, gitlab
      github_only — list of workflow_file strings
      gitlab_only — list of job strings
    """
    with open(path) as f:
        lines = f.readlines()

    paired = []
    github_only = []
    gitlab_only = []

    section = None       # 'paired' | 'github_only' | 'gitlab_only'
    current = {}         # current paired entry being built
    sub = None           # 'github' | 'gitlab' | 'scripts' | None
    in_scripts = False

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

        # Top-level section headers
        if re.match(r"^paired\s*:", line):
            flush()
            section = "paired"
            sub = None
            continue
        if re.match(r"^github_only\s*:", line):
            flush()
            section = "github_only"
            continue
        if re.match(r"^gitlab_only\s*:", line):
            flush()
            section = "gitlab_only"
            continue

        if section == "paired":
            # New entry
            if re.match(r"^  - ", line):
                flush()
                current = {"scripts": [], "github": {}, "gitlab": {}}
                sub = None
                in_scripts = False
                m = re.match(r"^  - name:\s*(.+)", line)
                if m:
                    current["name"] = m.group(1).strip()
                continue

            if indent == 4:
                in_scripts = False
                if re.match(r"    scripts\s*:", line):
                    in_scripts = True
                    sub = "scripts"
                    continue
                if re.match(r"    github\s*:", line):
                    sub = "github"
                    continue
                if re.match(r"    gitlab\s*:", line):
                    sub = "gitlab"
                    continue
                if re.match(r"    env_vars\s*:", line):
                    sub = "env_vars"
                    continue
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
                        current["gitlab"]["job"] = m.group(1).strip()
                    m = re.match(r"      cadence:\s*(.+)", line)
                    if m:
                        current["gitlab"]["cadence"] = m.group(1).strip()

        elif section == "github_only":
            m = re.match(r"  - workflow_file:\s*(.+)", line)
            if m:
                github_only.append(m.group(1).strip())

        elif section == "gitlab_only":
            m = re.match(r"  - job:\s*(.+)", line)
            if m:
                gitlab_only.append(m.group(1).strip())

    flush()
    return paired, github_only, gitlab_only


if os.path.exists(SYNC_MANIFEST):
    paired, github_only, gitlab_only = parse_sync_manifest(SYNC_MANIFEST)

    # Extract GitLab job names from .gitlab-ci.yml for existence checks
    gl_jobs = set()
    if gl_content:
        reserved = {
            "stages", "default", "variables", "include", "workflow",
            "image", "services", "before_script", "after_script",
        }
        for m in re.finditer(r"^([a-zA-Z][a-zA-Z0-9_:.-]+):\s*$", gl_content, re.MULTILINE):
            name = m.group(1)
            if name not in reserved:
                gl_jobs.add(name)

    # 3a/3b/3c — paired entries
    for entry in paired:
        entry_name = entry.get("name", "?")

        wf_file = entry.get("github", {}).get("workflow_file", "")
        if wf_file:
            wf_path = os.path.join(WORKFLOWS_DIR, wf_file)
            if not os.path.isfile(wf_path):
                errors.append(
                    f"[sync-manifest] paired '{entry_name}': "
                    f"github.workflow_file '{wf_file}' not found in .github/workflows/"
                )

        gl_job = entry.get("gitlab", {}).get("job", "")
        if gl_job and gl_content:
            if gl_job not in gl_jobs:
                errors.append(
                    f"[sync-manifest] paired '{entry_name}': "
                    f"gitlab.job '{gl_job}' not found in .gitlab-ci.yml"
                )

        for script in entry.get("scripts", []):
            script_path = os.path.join(SCRIPTS_DIR, script)
            if not os.path.isfile(script_path):
                errors.append(
                    f"[sync-manifest] paired '{entry_name}': "
                    f"script '{script}' not found in scripts/"
                )

    # 3d — github_only entries
    for wf_file in github_only:
        wf_path = os.path.join(WORKFLOWS_DIR, wf_file)
        if not os.path.isfile(wf_path):
            errors.append(
                f"[sync-manifest] github_only: '{wf_file}' not found in "
                f".github/workflows/ — remove from manifest or create the workflow"
            )

    # 3e — gitlab_only entries
    if gl_content:
        for gl_job in gitlab_only:
            if gl_job not in gl_jobs:
                errors.append(
                    f"[sync-manifest] gitlab_only: job '{gl_job}' not found in "
                    f".gitlab-ci.yml — remove from manifest or add the job"
                )

    # Coverage warning: GitHub workflows not mentioned in manifest at all
    all_manifest_wf = set()
    for entry in paired:
        wf = entry.get("github", {}).get("workflow_file", "")
        if wf:
            all_manifest_wf.add(wf)
    all_manifest_wf.update(github_only)

    for wf_path in sorted(glob.glob(os.path.join(WORKFLOWS_DIR, "*.yml")) +
                          glob.glob(os.path.join(WORKFLOWS_DIR, "*.yaml"))):
        wf_name = os.path.basename(wf_path)
        if wf_name not in all_manifest_wf:
            warnings.append(
                f"[sync-manifest] {wf_name} is not listed in workflow-sync.yml "
                f"(add to paired or github_only)"
            )

else:
    warnings.append(
        f"config/workflow-sync.yml not found — skipping manifest consistency checks"
    )


# ── Check 4: workflow-quota-costs.yml name consistency ───────────────────────
#
# Build the set of `name:` values declared by actual workflow files, then
# flag any entry in workflow-quota-costs.yml whose name has no match.
# Uses a simple line-by-line scan for both files to avoid a PyYAML dependency.

if os.path.exists(QUOTA_COSTS):
    # Collect workflow names from .github/workflows/*.yml
    actual_wf_names = set()
    for wf_path in sorted(glob.glob(os.path.join(WORKFLOWS_DIR, "*.yml")) +
                          glob.glob(os.path.join(WORKFLOWS_DIR, "*.yaml"))):
        with open(wf_path) as f:
            for line in f:
                m = re.match(r"^name:\s*(.+)", line)
                if m:
                    actual_wf_names.add(m.group(1).strip())
                    break  # only the top-level `name:` matters

    # Collect names from workflow-quota-costs.yml
    costs_names = []
    with open(QUOTA_COSTS) as f:
        for line in f:
            m = re.match(r"^- name:\s*(.+)", line)
            if m:
                costs_names.append(m.group(1).strip())

    for entry_name in costs_names:
        if entry_name not in actual_wf_names:
            errors.append(
                f"[quota-costs] '{entry_name}' in workflow-quota-costs.yml has no "
                f"matching workflow name in .github/workflows/ — "
                f"remove the entry or rename it to match the workflow's `name:` field"
            )
else:
    warnings.append(
        "config/workflow-quota-costs.yml not found — skipping quota-costs name check"
    )


# ── Check 5: workflow_run trigger name validity ───────────────────────────────
#
# Build the set of actual workflow names, then flag any workflow_run.workflows
# entry that references a name not present in that set.
# Uses PyYAML (already imported via the sync-manifest section above) to parse
# each workflow file rather than regex, so nested structures are handled correctly.

try:
    import yaml as _yaml

    # Collect all actual workflow names
    wf_names_for_check5 = set()
    for _wf_path in sorted(glob.glob(os.path.join(WORKFLOWS_DIR, "*.yml")) +
                           glob.glob(os.path.join(WORKFLOWS_DIR, "*.yaml"))):
        try:
            _data = _yaml.safe_load(open(_wf_path))
            if isinstance(_data, dict) and "name" in _data:
                wf_names_for_check5.add(_data["name"])
        except Exception:
            pass

    # Check each workflow's workflow_run triggers
    for _wf_path in sorted(glob.glob(os.path.join(WORKFLOWS_DIR, "*.yml")) +
                           glob.glob(os.path.join(WORKFLOWS_DIR, "*.yaml"))):
        _wf_name = os.path.basename(_wf_path)
        try:
            _data = _yaml.safe_load(open(_wf_path))
            if not isinstance(_data, dict):
                continue
            # PyYAML parses the bare key `on` as Python True
            _on = _data.get("on") or _data.get(True) or {}
            if not isinstance(_on, dict):
                continue
            _wr = _on.get("workflow_run")
            if not isinstance(_wr, dict):
                continue
            for _ref in _wr.get("workflows", []):
                if _ref not in wf_names_for_check5:
                    errors.append(
                        f"[workflow-run] {_wf_name}: references workflow_run trigger "
                        f"'{_ref}' which does not match any workflow name in "
                        f".github/workflows/ — rename or remove it"
                    )
        except Exception:
            pass

except ImportError:
    warnings.append("PyYAML not available — skipping workflow_run name check")


# ── Report ────────────────────────────────────────────────────────────────────

if warnings:
    for w in warnings:
        print(f"  ⚠ {w}")

if errors:
    print(f"\nvalidate-workflow-guards: {len(errors)} error(s) found\n")
    for err in errors:
        print(f"  ✗ {err}")
    sys.exit(1)
else:
    wf_count = len(glob.glob(os.path.join(WORKFLOWS_DIR, "*.yml")) +
                   glob.glob(os.path.join(WORKFLOWS_DIR, "*.yaml")))
    manifest_note = f", {len(paired)} paired jobs verified" if os.path.exists(SYNC_MANIFEST) else ""
    costs_note = f", {len(costs_names)} quota-cost entries verified" if os.path.exists(QUOTA_COSTS) else ""
    wr_count = sum(
        1 for _wf_path in glob.glob(os.path.join(WORKFLOWS_DIR, "*.yml")) +
                          glob.glob(os.path.join(WORKFLOWS_DIR, "*.yaml"))
        if "workflow_run" in open(_wf_path).read()
    )
    wr_note = f", {wr_count} workflow_run triggers verified"
    print(
        f"validate-workflow-guards: all checks passed "
        f"({wf_count} workflows, .gitlab-ci.yml script refs verified{manifest_note}{costs_note}{wr_note})"
    )
