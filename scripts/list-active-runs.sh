#!/usr/bin/env bash
#
# scripts/list-active-runs.sh — list active workflow runs with clickable URLs
#
# Fetches all in_progress and queued runs across the org and outputs:
#   - A Markdown table to GITHUB_STEP_SUMMARY (clickable in web UI)
#   - Plain URLs to stdout (one per line, openable via API/curl/app)
#
# The GitHub Android app opens github.com URLs natively when tapped.
# The step summary links are standard Markdown hyperlinks.
#
# Usage:
#   bash scripts/list-active-runs.sh [--org ORG] [--status STATUS]
#
# Options:
#   --org ORG        GitHub org to query (default: Interested-Deving-1896)
#   --status STATUS  Run status filter: queued|in_progress|all (default: all)
#   --json           Output JSON instead of plain URLs
#
# Required env vars:
#   GH_TOKEN  — PAT with actions:read scope
#   REPO      — owner/repo of fork-sync-all (for step summary context)

set -uo pipefail

ORG="${ORG:-Interested-Deving-1896}"
STATUS_FILTER="${STATUS_FILTER:-all}"
OUTPUT_JSON="${OUTPUT_JSON:-false}"
API="https://api.github.com"

info() { echo "[list-active-runs] $*" >&2; }

# ── Arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --org)    ORG="$2";           shift 2 ;;
    --status) STATUS_FILTER="$2"; shift 2 ;;
    --json)   OUTPUT_JSON="true"; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# ── Fetch runs ────────────────────────────────────────────────────────────────
fetch_runs() {
  local status="$1"
  curl -sf \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${API}/repos/${REPO}/actions/runs?status=${status}&per_page=100" \
    2>/dev/null || echo '{"workflow_runs":[]}'
}

# Collect runs based on filter
ALL_RUNS_JSON='[]'
if [[ "$STATUS_FILTER" == "all" || "$STATUS_FILTER" == "in_progress" ]]; then
  IN_PROGRESS=$(fetch_runs "in_progress")
  ALL_RUNS_JSON=$(echo "$ALL_RUNS_JSON" "$IN_PROGRESS" | python3 -c "
import json,sys
parts = sys.stdin.read().split('\n', 1)
a = json.loads(parts[0])
b = json.loads(parts[1]).get('workflow_runs', [])
print(json.dumps(a + b))
" 2>/dev/null || echo '[]')
fi
if [[ "$STATUS_FILTER" == "all" || "$STATUS_FILTER" == "queued" ]]; then
  QUEUED=$(fetch_runs "queued")
  ALL_RUNS_JSON=$(echo "$ALL_RUNS_JSON" "$QUEUED" | python3 -c "
import json,sys
parts = sys.stdin.read().split('\n', 1)
a = json.loads(parts[0])
b = json.loads(parts[1]).get('workflow_runs', [])
print(json.dumps(a + b))
" 2>/dev/null || echo '[]')
fi

# ── Process and output ────────────────────────────────────────────────────────
python3 - << PYEOF
import json, sys, os
from datetime import datetime, timezone

runs = json.loads('''${ALL_RUNS_JSON}'''.replace("'", "\\'"))

# Sort: in_progress first, then queued; within each by created_at desc
def sort_key(r):
    status_order = {'in_progress': 0, 'queued': 1}.get(r.get('status',''), 2)
    return (status_order, r.get('created_at',''))

runs.sort(key=sort_key)

output_json = os.environ.get('OUTPUT_JSON', 'false') == 'true'
summary_file = os.environ.get('GITHUB_STEP_SUMMARY', '')

if output_json:
    out = []
    for r in runs:
        out.append({
            'run_number': r.get('run_number'),
            'name': r.get('name'),
            'status': r.get('status'),
            'branch': r.get('head_branch'),
            'created_at': r.get('created_at'),
            'url': r.get('html_url'),
            'api_url': r.get('url'),
        })
    print(json.dumps(out, indent=2))
else:
    # Plain URLs to stdout
    for r in runs:
        print(r.get('html_url',''))

# Write Markdown summary
if summary_file:
    now = datetime.now(timezone.utc).strftime('%H:%M:%S UTC')
    lines = []
    lines.append(f'## Active Workflow Runs — {now}')
    lines.append('')
    lines.append(f'**{len(runs)} run(s)** across in_progress + queued')
    lines.append('')

    if not runs:
        lines.append('_No active runs._')
    else:
        lines.append('| # | Workflow | Status | Branch | Age | Links |')
        lines.append('|---|---|---|---|---|---|')
        for r in runs:
            num     = r.get('run_number', '?')
            name    = r.get('name', '?')
            status  = r.get('status', '?')
            branch  = r.get('head_branch', '?')
            url     = r.get('html_url', '')
            api_url = r.get('url', '')
            created = r.get('created_at', '')

            # Age
            try:
                dt = datetime.fromisoformat(created.replace('Z', '+00:00'))
                age_s = int((datetime.now(timezone.utc) - dt).total_seconds())
                age = f'{age_s//3600}h {(age_s%3600)//60}m' if age_s >= 3600 else f'{age_s//60}m {age_s%60}s'
            except Exception:
                age = '?'

            # Status emoji
            emoji = {'in_progress': '🟡', 'queued': '🟠'}.get(status, '⚪')

            # Links: web URL + API URL
            links = f'[Web]({url}) · [API]({api_url})'

            lines.append(f'| {num} | [{name}]({url}) | {emoji} {status} | `{branch}` | {age} | {links} |')

    lines.append('')
    lines.append('---')
    lines.append('_Links open in browser, GitHub mobile app, or any HTTP client._')
    lines.append(f'_API URLs require `Authorization: token <GH_TOKEN>` header._')

    with open(summary_file, 'a') as f:
        f.write('\n'.join(lines) + '\n')

    import sys
    print(f'[list-active-runs] Summary written ({len(runs)} runs)', file=sys.stderr)
PYEOF
