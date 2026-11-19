#!/usr/bin/env bash
# POST /api/fsa/notifications/triage
# Auto-marks known-safe notification patterns as read.
# Delegates to scripts/notifications.sh --auto-triage.
#
# Body (JSON): { "dry_run": false }
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/fsa-adapter.sh"

DRY_RUN="${BODY_dry_run:-false}"

NOTIF_SCRIPT="${_FSA_ROOT}/scripts/notifications.sh"
if [[ ! -f "$NOTIF_SCRIPT" ]]; then
  fsa_error "notifications.sh not found" 500
  exit 0
fi

if [[ "$DRY_RUN" == "true" ]]; then
  # Just list what would be triaged
  output=$(GH_TOKEN="$GH_TOKEN" bash "$NOTIF_SCRIPT" --list --json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
safe_patterns = [
    'Mirror to OpenOS-Project-OSP', 'Sync btrfs-devel Branches',
    'Rate limit', 'rate limit', 'Quota', 'quota exhausted',
    'Dependabot', 'chore(deps)', 'chore: bump', 'build(deps)',
]
would_triage = [n for n in data if any(p in n.get('subject',{}).get('title','') for p in safe_patterns)]
print(json.dumps({'ok': True, 'dry_run': True, 'would_triage': len(would_triage), 'items': [n['id'] for n in would_triage]}))
" 2>/dev/null || echo '{"ok":false,"error":"failed to list notifications"}')
  echo "$output"
else
  GH_TOKEN="$GH_TOKEN" bash "$NOTIF_SCRIPT" --auto-triage >/dev/null 2>&1
  echo "{\"ok\":true,\"dry_run\":false,\"message\":\"Auto-triage complete\"}"
fi
