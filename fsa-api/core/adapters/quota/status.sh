#!/usr/bin/env bash
# GET /api/fsa/quota
# Returns current GitHub API quota status for all rate limit buckets.
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/fsa-adapter.sh"

result=$(fsa_api_get "/rate_limit")

echo "$result" | python3 -c "
import json, sys
from datetime import datetime, timezone

d = json.load(sys.stdin)
resources = d.get('resources', {})
output = {'ok': True, 'buckets': {}}

for bucket, data in resources.items():
    remaining = data.get('remaining', 0)
    limit = data.get('limit', 0)
    reset_epoch = data.get('reset', 0)
    try:
        reset_dt = datetime.fromtimestamp(reset_epoch, tz=timezone.utc)
        now = datetime.now(timezone.utc)
        wait_secs = max(0, int((reset_dt - now).total_seconds()))
        reset_in = f'{wait_secs//60}m {wait_secs%60}s' if wait_secs > 0 else 'now'
        reset_at = reset_dt.strftime('%H:%M:%S UTC')
    except Exception:
        reset_in = 'unknown'
        reset_at = 'unknown'

    pct = round(remaining / limit * 100) if limit > 0 else 0
    output['buckets'][bucket] = {
        'remaining': remaining,
        'limit': limit,
        'used': limit - remaining,
        'pct_remaining': pct,
        'reset_in': reset_in,
        'reset_at': reset_at,
        'healthy': remaining > 200,
    }

# Top-level summary from core bucket
core = output['buckets'].get('core', {})
output['remaining'] = core.get('remaining', 0)
output['limit'] = core.get('limit', 0)
output['reset_in'] = core.get('reset_in', 'unknown')
output['healthy'] = core.get('healthy', False)

print(json.dumps(output, indent=2))
" 2>/dev/null
