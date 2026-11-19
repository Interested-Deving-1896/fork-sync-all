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
import os, json, sys
from datetime import datetime, timezone

# Load time_format from the includes directory alongside this script
_script_dir = os.path.dirname(os.path.abspath(__file__))
_includes_dir = os.path.join(_script_dir, "includes")
sys.path.insert(0, _includes_dir)
try:
    from time_format import fmt_dt
    _have_tf = True
except ImportError:
    _have_tf = False

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

now_dt = datetime.now(timezone.utc)
if _have_tf:
    tf = fmt_dt(now_dt)
    now_24   = tf["utc_24"]
    now_12   = tf["utc_12"]
    now_date = tf["json_extra"]["utc_date"]
    now_display = tf["display"]
    now_str  = f"{now_date} {now_24} / {now_12}"
else:
    now_str     = now_dt.strftime("%Y-%m-%d %H:%M UTC")
    now_display = now_str

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
    f"| **Time (UTC)** | {now_str} |",
    f"| **Run** | [#{rnum}](https://github.com/{repo}/actions/runs/{rid}) |",
]

if _have_tf:
    lines += [
        "",
        "<details><summary>Run time — all timezones</summary>",
        "",
        now_display,
        "",
        "</details>",
    ]

if inputs:
    lines += ["", "### Inputs", "", "| Input | Value |", "|---|---|"]
    for k, v in sorted(inputs.items()):
        lines.append(f"| \`{k}\` | \`{v}\` |")

summary_path = os.environ.get("GITHUB_STEP_SUMMARY", "/dev/null")
with open(summary_path, "a") as f:
    f.write("\n".join(lines) + "\n")

# Echo inputs to stdout so the rate-limit-rerun loop guard can detect
# rate_limit_rerun=true in the job logs zip (GITHUB_STEP_SUMMARY is not
# included in the logs zip — only runner stdout/stderr is).
if inputs:
    print("INPUTS_JSON=" + json.dumps(inputs, separators=(',', ':')))
PYEOF
