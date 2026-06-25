#!/usr/bin/env bash
# GET /api/fsa/workflows/:name/status
# Returns the last N runs for a workflow with conclusion, timing, and logs URL.
#
# Path param:  :name  — workflow filename or display name
# Query param: ?limit=N  (default: 5)
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/fsa-adapter.sh"

WORKFLOW_NAME="${PATH_name:-}"
LIMIT="${QUERY_limit:-5}"

[[ -z "$WORKFLOW_NAME" ]] && { fsa_error "workflow name required" 400; exit 0; }

# Resolve filename
resolve_workflow_file() {
  local name="$1"
  local dir="${_FSA_ROOT}/.github/workflows"
  [[ -f "${dir}/${name}" ]] && echo "$name" && return
  [[ -f "${dir}/${name}.yml" ]] && echo "${name}.yml" && return
  for f in "${dir}"/*.yml "${dir}"/*.yaml; do
    [[ -f "$f" ]] || continue
    wname=$(python3 -c "import yaml; d=yaml.safe_load(open('$f')); print(d.get('name',''))" 2>/dev/null || echo "")
    [[ "$wname" == "$name" ]] && echo "$(basename "$f")" && return
  done
  echo ""
}

workflow_file=$(resolve_workflow_file "$WORKFLOW_NAME")
[[ -z "$workflow_file" ]] && { fsa_error "workflow not found: ${WORKFLOW_NAME}" 404; exit 0; }

fsa_quota_check 50 || exit 0

runs=$(fsa_api_get "/repos/${FSA_REPO}/actions/workflows/${workflow_file}/runs?per_page=${LIMIT}")

echo "$runs" | python3 -c "
import json, sys
from datetime import datetime, timezone

d = json.load(sys.stdin)
runs = d.get('workflow_runs', [])
items = []
for r in runs:
    created = r.get('created_at', '')
    updated = r.get('updated_at', '')
    try:
        dt = datetime.fromisoformat(created.replace('Z', '+00:00'))
        delta = datetime.now(timezone.utc) - dt
        mins = int(delta.total_seconds() / 60)
        age = f'{mins}m ago' if mins < 60 else f'{mins//60}h ago' if mins < 1440 else f'{mins//1440}d ago'
    except Exception:
        age = created[:10]
    items.append({
        'id': r['id'],
        'status': r.get('status'),
        'conclusion': r.get('conclusion'),
        'age': age,
        'created_at': created,
        'html_url': r.get('html_url'),
        'head_branch': r.get('head_branch'),
        'head_sha': r.get('head_sha', '')[:8],
        'event': r.get('event'),
        'run_number': r.get('run_number'),
    })
print(json.dumps({'ok': True, 'workflow': '${workflow_file}', 'count': len(items), 'runs': items}, indent=2))
" 2>/dev/null
