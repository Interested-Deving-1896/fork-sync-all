#!/usr/bin/env bash
# adapters/github/issue-report.sh — monthly issue report for an org
# GET /api/github/org/report?org=<org>&month=YYYY-MM
#
# Adapted from locus313/github-api-scripts monthly reporting pattern.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/lib/adapter.sh"

GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
[[ -z "$GH_TOKEN" ]] && { respond_error 500 "GH_TOKEN not set"; exit 0; }

ORG="$(query_param org "")"
MONTH="$(query_param month "$(date -u '+%Y-%m')")"
[[ -z "$ORG" ]] && { respond_error 400 "missing org parameter"; exit 0; }

# Validate month format
if ! echo "$MONTH" | grep -qE '^[0-9]{4}-[0-9]{2}$'; then
  respond_error 400 "invalid month format (expected YYYY-MM)"
  exit 0
fi

SINCE="${MONTH}-01T00:00:00Z"
# Last day of month
UNTIL="$(python3 -c "
import datetime
y,m = map(int, '${MONTH}'.split('-'))
if m == 12: end = datetime.date(y+1,1,1)
else:       end = datetime.date(y,m+1,1)
print(end.strftime('%Y-%m-%dT00:00:00Z'))
")"

# GraphQL: fetch repos, then REST for issues (GraphQL issues search is complex)
repos_result="$(curl -sf \
  -H "Authorization: token $GH_TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.github.com/graphql" \
  -d "{\"query\":\"{ organization(login: \\\"${ORG}\\\") { repositories(first: 50, orderBy: {field: PUSHED_AT, direction: DESC}) { nodes { name } } } }\"}" \
  2>/dev/null || echo "{}")"

python3 - "$repos_result" "$ORG" "$MONTH" "$SINCE" "$UNTIL" "$GH_TOKEN" << 'PYEOF'
import json, sys, urllib.request

repos_raw, org, month, since, until, token = sys.argv[1:]
data = json.loads(repos_raw)
repos = [n['name'] for n in data.get('data',{}).get('organization',{})
         .get('repositories',{}).get('nodes',[])]

headers = {'Authorization': f'token {token}', 'Accept': 'application/vnd.github+json'}
summary = []

for repo in repos[:20]:  # cap at 20 repos to stay within quota
    url = (f"https://api.github.com/repos/{org}/{repo}/issues"
           f"?state=all&since={since}&per_page=100")
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=10) as r:
            issues = json.load(r)
    except Exception:
        continue

    opened = [i for i in issues if i.get('created_at','') >= since
              and i.get('created_at','') < until and 'pull_request' not in i]
    closed = [i for i in issues if i.get('closed_at') and
              i.get('closed_at','') >= since and i.get('closed_at','') < until
              and 'pull_request' not in i]

    if opened or closed:
        contributors = list({i['user']['login'] for i in opened + closed if i.get('user')})
        summary.append({
            "repo": repo,
            "opened": len(opened),
            "closed": len(closed),
            "contributors": contributors
        })

total_opened = sum(r['opened'] for r in summary)
total_closed = sum(r['closed'] for r in summary)
all_contributors = list({c for r in summary for c in r['contributors']})

print(json.dumps({
    "org": org, "month": month,
    "total_opened": total_opened,
    "total_closed": total_closed,
    "unique_contributors": len(all_contributors),
    "contributors": all_contributors,
    "repos": summary
}, indent=2))
PYEOF
