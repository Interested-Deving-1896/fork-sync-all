#!/usr/bin/env bash
# GET /api/fsa/notifications
# Returns unread GitHub notifications with reason, repo, and age.
#
# Query params:
#   ?scope=unread|all|participating  (default: unread)
#   ?limit=N                         (default: 50)
#   ?filter=<reason>                 (ci_activity|mention|review_requested|all)
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/fsa-adapter.sh"

SCOPE="${QUERY_scope:-unread}"
LIMIT="${QUERY_limit:-50}"
FILTER="${QUERY_filter:-all}"

all_flag="false"
[[ "$SCOPE" == "all" ]] && all_flag="true"
participating_flag="false"
[[ "$SCOPE" == "participating" ]] && participating_flag="true"

result=$(fsa_api_get "/notifications?all=${all_flag}&participating=${participating_flag}&per_page=${LIMIT}")

echo "$result" | python3 -c "
import json, sys
from datetime import datetime, timezone

data = json.load(sys.stdin)
if not isinstance(data, list):
    print(json.dumps({'ok': False, 'error': 'unexpected response', 'raw': str(data)[:200]}))
    sys.exit(0)

filter_reason = '${FILTER}'
items = []
for n in data:
    reason = n.get('reason', '')
    if filter_reason != 'all' and reason != filter_reason:
        continue
    updated = n.get('updated_at', '')
    try:
        dt = datetime.fromisoformat(updated.replace('Z', '+00:00'))
        delta = datetime.now(timezone.utc) - dt
        mins = int(delta.total_seconds() / 60)
        age = f'{mins}m ago' if mins < 60 else f'{mins//60}h ago' if mins < 1440 else f'{mins//1440}d ago'
    except Exception:
        age = updated[:10]
    items.append({
        'id': n['id'],
        'reason': reason,
        'repo': n.get('repository', {}).get('full_name', ''),
        'title': n.get('subject', {}).get('title', ''),
        'type': n.get('subject', {}).get('type', ''),
        'age': age,
        'updated_at': updated,
        'unread': n.get('unread', True),
    })

by_reason = {}
for item in items:
    r = item['reason']
    by_reason[r] = by_reason.get(r, 0) + 1

print(json.dumps({
    'ok': True,
    'count': len(items),
    'by_reason': by_reason,
    'items': items,
}, indent=2))
" 2>/dev/null
