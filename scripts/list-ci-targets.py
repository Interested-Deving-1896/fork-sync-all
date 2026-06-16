#!/usr/bin/env python3
"""
scripts/list-ci-targets.py — emit enabled CI check targets as JSON for
the check-ci.yml matrix job.

Usage:
  python3 scripts/list-ci-targets.py [--target-id ID]

Reads config/ci-check-targets.yml and prints a JSON array of enabled
targets, optionally filtered to a single target ID.
"""
import json
import os
import sys
import yaml

config_path = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "config", "ci-check-targets.yml"
)

with open(config_path) as f:
    data = yaml.safe_load(f)

filt = ""
if len(sys.argv) > 2 and sys.argv[1] == "--target-id":
    filt = sys.argv[2].strip()

out = []
for t in (data.get("targets") or []):
    if not t.get("enabled", True):
        continue
    if filt and t["id"] != filt:
        continue
    out.append({
        "id":               t["id"],
        "platform":         t["platform"],
        "org":              t.get("org", t.get("group", "")),
        "subgroups_config": t.get("subgroups_config", ""),
        "token_secret":     t.get("token_secret", "SYNC_TOKEN"),
        "api_url":          t.get("api_url", ""),
    })

print(json.dumps(out))
