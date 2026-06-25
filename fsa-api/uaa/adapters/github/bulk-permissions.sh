#!/usr/bin/env bash
# adapters/github/bulk-permissions.sh — set team permissions across all org repos
# POST /api/github/org/permissions
# Body: {"org":"...","team":"...","permission":"push|pull|admin|maintain|triage"}
#
# Adapted from locus313/github-api-scripts bulk permission management pattern.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/lib/adapter.sh"

auth_check

GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
[[ -z "$GH_TOKEN" ]] && { respond_error 500 "GH_TOKEN not set"; exit 0; }

body="$(request_body)"
tmp="$(mktemp)"
echo "$body" > "$tmp"

python3 - "$tmp" "$GH_TOKEN" << 'PYEOF'
import json, sys, os, urllib.request, urllib.error

tmp_file, token = sys.argv[1], sys.argv[2]
with open(tmp_file) as f:
    req = json.load(f)
os.unlink(tmp_file)

org        = req.get('org', '')
team       = req.get('team', '')
permission = req.get('permission', 'push')
dry_run    = req.get('dry_run', False)

if not org or not team:
    print(json.dumps({"error": "missing org or team"}))
    sys.exit(0)

valid_perms = {'pull', 'push', 'admin', 'maintain', 'triage'}
if permission not in valid_perms:
    print(json.dumps({"error": f"invalid permission: {permission}. valid: {sorted(valid_perms)}"}))
    sys.exit(0)

headers = {
    'Authorization': f'token {token}',
    'Accept': 'application/vnd.github+json',
    'Content-Type': 'application/json'
}

def gh_get(url):
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req) as r:
        return json.load(r)

# Fetch all repos via GraphQL (1 call)
gql = f'{{ organization(login: "{org}") {{ repositories(first: 100) {{ nodes {{ name }} }} }} }}'
gql_req = urllib.request.Request(
    'https://api.github.com/graphql',
    data=json.dumps({"query": gql}).encode(),
    headers=headers,
    method='POST'
)
with urllib.request.urlopen(gql_req) as r:
    gql_data = json.load(r)

repos = [n['name'] for n in gql_data.get('data', {}).get('organization', {})
         .get('repositories', {}).get('nodes', [])]

results = []
for repo_name in repos:
    url = f"https://api.github.com/orgs/{org}/teams/{team}/repos/{org}/{repo_name}"
    payload = json.dumps({"permission": permission}).encode()
    if dry_run:
        results.append({"repo": repo_name, "status": "dry-run"})
        continue
    try:
        put_req = urllib.request.Request(url, data=payload, headers=headers, method='PUT')
        with urllib.request.urlopen(put_req) as r:
            results.append({"repo": repo_name, "status": "ok"})
    except urllib.error.HTTPError as e:
        results.append({"repo": repo_name, "status": "error", "code": e.code})

print(json.dumps({
    "org": org, "team": team, "permission": permission,
    "dry_run": dry_run, "count": len(results), "results": results
}, indent=2))
PYEOF
