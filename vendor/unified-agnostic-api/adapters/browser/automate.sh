#!/usr/bin/env bash
# adapters/browser/automate.sh — run a sequence of browser actions via CDP
# POST /api/browser/automate
# Body: {"url":"...","steps":[{"action":"click","selector":"..."},{"action":"type","selector":"...","text":"..."},{"action":"wait","ms":500}]}
#
# Uses tools/automate.js (Puppeteer) if available, otherwise returns a
# dry-run plan showing what would be executed.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/lib/adapter.sh"

auth_check

body="$(request_body)"
[[ -z "$body" ]] && { respond_error 400 "empty request body"; exit 0; }

tmp="$(mktemp)"
echo "$body" > "$tmp"

if command -v node &>/dev/null && [[ -f "$REPO_ROOT/tools/automate.js" ]]; then
  result="$(node "$REPO_ROOT/tools/automate.js" "$tmp" 2>/dev/null)"
  rm -f "$tmp"
  printf '%s\n' "$result"
else
  # Dry-run: parse and return the step plan
  python3 - "$tmp" << 'PYEOF'
import json, sys, os

tmp = sys.argv[1]
with open(tmp) as f:
    req = json.load(f)
os.unlink(tmp)

url   = req.get('url', '')
steps = req.get('steps', [])

valid_actions = {'click', 'type', 'wait', 'scroll', 'navigate', 'screenshot', 'evaluate'}
plan = []
for i, step in enumerate(steps):
    action = step.get('action', '')
    if action not in valid_actions:
        plan.append({"step": i, "action": action, "status": "unknown-action"})
    else:
        plan.append({"step": i, "action": action,
                     "selector": step.get('selector', ''),
                     "status": "dry-run"})

print(json.dumps({
    "url": url,
    "steps": len(steps),
    "plan": plan,
    "executed": False,
    "note": "Install puppeteer (npm i puppeteer) and tools/automate.js for live execution"
}, indent=2))
PYEOF
fi
