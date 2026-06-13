#!/usr/bin/env python3
"""
check-workflow-yaml.py

Parses every .github/workflows/*.yml file with PyYAML and exits non-zero
if any file fails to parse. Run by validate-config.yml before the full
validate-workflow-guards.py sweep so YAML errors surface with a clear
message rather than a cryptic guards failure.

Exit codes:
  0 — all files parse as valid YAML
  1 — one or more files have YAML errors
"""

import glob
import os
import sys
import yaml

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKFLOWS_DIR = os.path.join(REPO_ROOT, ".github", "workflows")

files = sorted(
    glob.glob(os.path.join(WORKFLOWS_DIR, "*.yml")) +
    glob.glob(os.path.join(WORKFLOWS_DIR, "*.yaml"))
)

errors = []
for fpath in files:
    try:
        yaml.safe_load(open(fpath))
    except yaml.YAMLError as e:
        errors.append((fpath, str(e)))

if errors:
    print(f"YAML parse errors in {len(errors)} of {len(files)} workflow file(s):")
    for fpath, msg in errors:
        rel = os.path.relpath(fpath, REPO_ROOT)
        print(f"  {rel}")
        # Print first line of error only — full message can be verbose
        print(f"    {msg.splitlines()[0]}")
    sys.exit(1)

print(f"All {len(files)} workflow files parse as valid YAML")
