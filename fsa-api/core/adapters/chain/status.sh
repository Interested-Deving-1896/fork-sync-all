#!/usr/bin/env bash
# GET /api/fsa/chain/status
# Returns the current mirror chain status: last run of each chain workflow,
# FLUSH_ACTIVE mutex state, and overall health.
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/fsa-adapter.sh"

fsa_quota_check 150 || exit 0

CHAIN_WORKFLOWS=(
  "mirror-to-osp.yml"
  "mirror-osp-to-ooc.yml"
  "mirror-osp-to-gitlab.yml"
  "pre-mirror-ci-gate.yml"
  "post-flush-verify.yml"
  "flush-lifecycle.yml"
  "full-chain-flush.yml"
)

# Fetch FLUSH_ACTIVE variable
flush_active=$(fsa_api_get "/repos/${FSA_REPO}/actions/variables/FLUSH_ACTIVE" \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('value','false'))" 2>/dev/null || echo "false")
flush_updated=$(fsa_api_get "/repos/${FSA_REPO}/actions/variables/FLUSH_ACTIVE" \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('updated_at',''))" 2>/dev/null || echo "")

# Fetch last run for each chain workflow
chain_status=()
for wf in "${CHAIN_WORKFLOWS[@]}"; do
  run=$(fsa_api_get "/repos/${FSA_REPO}/actions/workflows/${wf}/runs?per_page=1")
  chain_status+=("$(echo "$run" | python3 -c "
import json,sys
from datetime import datetime, timezone
d=json.load(sys.stdin)
runs=d.get('workflow_runs',[])
if not runs:
    print(json.dumps({'workflow':'${wf}','status':'never_run','conclusion':None,'age':None,'url':None}))
    sys.exit(0)
r=runs[0]
created=r.get('created_at','')
try:
    dt=datetime.fromisoformat(created.replace('Z','+00:00'))
    delta=datetime.now(timezone.utc)-dt
    mins=int(delta.total_seconds()/60)
    age=f'{mins}m ago' if mins<60 else f'{mins//60}h ago' if mins<1440 else f'{mins//1440}d ago'
except:
    age=created[:10]
print(json.dumps({'workflow':'${wf}','status':r.get('status'),'conclusion':r.get('conclusion'),'age':age,'url':r.get('html_url')}))
" 2>/dev/null || echo "{\"workflow\":\"${wf}\",\"status\":\"error\"}")")
done

# Assemble output
python3 - << PYEOF
import json, sys
from datetime import datetime, timezone

chain = [json.loads(s) for s in """$(printf '%s\n' "${chain_status[@]}")""".strip().split('\n') if s.strip()]

# Overall health: all completed workflows should have conclusion=success or skipped
healthy = all(
    c.get('conclusion') in ('success', 'skipped', None) or c.get('status') == 'never_run'
    for c in chain
)

flush_active = '${flush_active}' == 'true'
flush_updated = '${flush_updated}'

# TTL check: treat FLUSH_ACTIVE as stale if >8h old
flush_stale = False
if flush_active and flush_updated:
    try:
        dt = datetime.fromisoformat(flush_updated.replace('Z', '+00:00'))
        age_h = (datetime.now(timezone.utc) - dt).total_seconds() / 3600
        flush_stale = age_h > 8
    except Exception:
        pass

print(json.dumps({
    'ok': True,
    'healthy': healthy and not (flush_active and not flush_stale),
    'flush_active': flush_active,
    'flush_stale': flush_stale,
    'flush_updated': flush_updated,
    'chain': chain,
}, indent=2))
PYEOF
