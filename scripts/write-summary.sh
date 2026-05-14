#!/usr/bin/env bash
#
# Writes a Markdown job summary to $GITHUB_STEP_SUMMARY.
# Called as the last step of every workflow job via:
#
#   - name: Write summary
#     if: always()
#     env:
#       JOB_STATUS: ${{ job.status }}
#       INPUTS_JSON: ${{ toJSON(inputs) }}
#     run: bash scripts/write-summary.sh
#
# All other values are read from standard GitHub Actions environment
# variables (GITHUB_WORKFLOW, GITHUB_RUN_NUMBER, etc.) which are always
# available without explicit env: mapping.

set -uo pipefail

JOB_STATUS="${JOB_STATUS:-unknown}"
INPUTS_JSON="${INPUTS_JSON:-{}}"

python3 - << PYEOF
import os, json
from datetime import datetime, timezone

wf     = os.environ.get("GITHUB_WORKFLOW", "")
rid    = os.environ.get("GITHUB_RUN_ID", "")
rnum   = os.environ.get("GITHUB_RUN_NUMBER", "")
actor  = os.environ.get("GITHUB_ACTOR", "")
event  = os.environ.get("GITHUB_EVENT_NAME", "")
ref    = os.environ.get("GITHUB_REF_NAME", "")
sha    = os.environ.get("GITHUB_SHA", "")[:7]
repo   = os.environ.get("GITHUB_REPOSITORY", "")
status = os.environ.get("JOB_STATUS", "unknown")
inputs_raw = os.environ.get("INPUTS_JSON", "{}")
now    = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

icon = {"success": "✅", "failure": "❌", "cancelled": "⚠️"}.get(status, "⏳")

try:
    inputs = json.loads(inputs_raw) or {}
except Exception:
    inputs = {}

lines = [
    f"## {icon} {wf} — Run #{rnum}",
    "",
    "| | |",
    "|---|---|",
    f"| **Status** | {icon} {status} |",
    f"| **Triggered by** | {actor} via \`{event}\` |",
    f"| **Ref** | \`{ref}\` @ \`{sha}\` |",
    f"| **Time** | {now} |",
    f"| **Run** | [#{rnum}](https://github.com/{repo}/actions/runs/{rid}) |",
]

if inputs:
    lines += ["", "### Inputs", "", "| Input | Value |", "|---|---|"]
    for k, v in sorted(inputs.items()):
        lines.append(f"| \`{k}\` | \`{v}\` |")

summary_path = os.environ.get("GITHUB_STEP_SUMMARY", "/dev/null")
with open(summary_path, "a") as f:
    f.write("\n".join(lines) + "\n")
PYEOF
