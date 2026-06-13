#!/usr/bin/env python3
"""
Detects newly added repos from a push to registered-imports.json or
config/template-consumers.yml by diffing HEAD~1 vs HEAD.

Outputs a JSON array to stdout:
  [{"name": "repo-name", "profile": "...", "upstream_url": "..."}, ...]

Used by the detect job in onboard-repo.yml.
"""
import json
import subprocess
import sys

import yaml

results = []
seen = set()


def add(name, profile="", upstream_url=""):
    if name and name not in seen:
        seen.add(name)
        results.append({"name": name, "profile": profile, "upstream_url": upstream_url})


# ── New entries in registered-imports.json ────────────────────────────────────
try:
    old = subprocess.run(
        ["git", "show", "HEAD~1:registered-imports.json"],
        capture_output=True, text=True
    )
    new = subprocess.run(
        ["git", "show", "HEAD:registered-imports.json"],
        capture_output=True, text=True
    )
    if old.returncode == 0 and new.returncode == 0:
        old_names = {e["target_name"] for e in json.loads(old.stdout)}
        for e in json.loads(new.stdout):
            if e["target_name"] not in old_names:
                add(e["target_name"], upstream_url=e.get("source_url", ""))
except Exception as ex:
    print(f"imports diff error: {ex}", file=sys.stderr)

# ── New entries in config/template-consumers.yml ──────────────────────────────
try:
    old = subprocess.run(
        ["git", "show", "HEAD~1:config/template-consumers.yml"],
        capture_output=True, text=True
    )
    if old.returncode == 0:
        old_names = {
            c["name"]
            for c in (yaml.safe_load(old.stdout) or {}).get("consumers", [])
        }
        with open("config/template-consumers.yml") as f:
            new_consumers = (yaml.safe_load(f) or {}).get("consumers", [])
        for c in new_consumers:
            if c["name"] not in old_names:
                add(c["name"], profile=c.get("profile", ""))
except Exception as ex:
    print(f"consumers diff error: {ex}", file=sys.stderr)

print(json.dumps(results))
