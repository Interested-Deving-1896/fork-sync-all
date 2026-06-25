#!/usr/bin/env bash
# GET /api/fsa/repos
# Lists repos in the FSA org via GraphQL (1 API call regardless of repo count).
#
# Query params:
#   ?type=all|public|private|fork|source  (default: all)
#   ?limit=N                               (default: 100)
#   ?filter=<substring>                    (filter by name)
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/fsa-adapter.sh"

TYPE="${QUERY_type:-all}"
LIMIT="${QUERY_limit:-100}"
FILTER="${QUERY_filter:-}"

fsa_quota_check 50 || exit 0

result=$(fsa_graphql "
{
  organization(login: \"${FSA_ORG}\") {
    repositories(first: ${LIMIT}, orderBy: {field: PUSHED_AT, direction: DESC}) {
      nodes {
        name
        nameWithOwner
        isPrivate
        isFork
        isArchived
        pushedAt
        defaultBranchRef { name }
        stargazerCount
        description
        url
        primaryLanguage { name }
      }
      pageInfo { hasNextPage endCursor }
      totalCount
    }
  }
}")

echo "$result" | python3 -c "
import json, sys
from datetime import datetime, timezone

d = json.load(sys.stdin)
nodes = d.get('data', {}).get('organization', {}).get('repositories', {}).get('nodes', [])
total = d.get('data', {}).get('organization', {}).get('repositories', {}).get('totalCount', 0)
has_next = d.get('data', {}).get('organization', {}).get('repositories', {}).get('pageInfo', {}).get('hasNextPage', False)

type_filter = '${TYPE}'
name_filter = '${FILTER}'.lower()

items = []
for r in nodes:
    if type_filter == 'fork' and not r.get('isFork'):
        continue
    if type_filter == 'source' and r.get('isFork'):
        continue
    if type_filter == 'private' and not r.get('isPrivate'):
        continue
    if type_filter == 'public' and r.get('isPrivate'):
        continue
    if name_filter and name_filter not in r.get('name', '').lower():
        continue

    pushed = r.get('pushedAt', '')
    try:
        dt = datetime.fromisoformat(pushed.replace('Z', '+00:00'))
        delta = datetime.now(timezone.utc) - dt
        days = delta.days
        age = f'{days}d ago' if days > 0 else 'today'
    except Exception:
        age = pushed[:10]

    items.append({
        'name': r.get('name'),
        'full_name': r.get('nameWithOwner'),
        'private': r.get('isPrivate'),
        'fork': r.get('isFork'),
        'archived': r.get('isArchived'),
        'default_branch': (r.get('defaultBranchRef') or {}).get('name', 'main'),
        'language': (r.get('primaryLanguage') or {}).get('name'),
        'stars': r.get('stargazerCount', 0),
        'description': r.get('description'),
        'url': r.get('url'),
        'pushed_age': age,
        'pushed_at': pushed,
    })

print(json.dumps({
    'ok': True,
    'org': '${FSA_ORG}',
    'total_count': total,
    'has_more': has_next,
    'count': len(items),
    'items': items,
}, indent=2))
" 2>/dev/null
