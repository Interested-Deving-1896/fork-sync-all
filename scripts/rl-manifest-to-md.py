#!/usr/bin/env python3
"""
Renders a rate-limit manifest JSON file as a Markdown table row per entry.
Used by rate-limit-rerun.yml to avoid inline f-strings with backticks
that confuse YAML parsers.

Usage: python3 rl-manifest-to-md.py <manifest.json>
"""
import json, sys

path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/rl-manifest.json"
with open(path) as f:
    entries = json.load(f)

for e in entries:
    mins = e["reset_in_sec"] // 60
    secs = e["reset_in_sec"] % 60
    wf   = e["workflow"]
    rid  = e["run_id"]
    print(f"| {rid} | `{wf}` | {mins}m {secs}s |")
