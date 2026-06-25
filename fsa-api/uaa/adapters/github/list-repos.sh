#!/usr/bin/env bash
# adapters/github/list-repos.sh — list repos for a GitHub org or user
# GET /api/github/repos?org=<org>&type=all|public|private&limit=100
#
# Uses GraphQL for efficiency (1 API call regardless of repo count).
# Patterns from locus313/github-api-scripts and alexkli/github-api-scripts.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/lib/adapter.sh"

GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
[[ -z "$GH_TOKEN" ]] && { respond_error 500 "GH_TOKEN not set"; exit 0; }

ORG="$(query_param org "")"
TYPE="$(query_param type "all")"
LIMIT="$(query_param limit "100")"

[[ -z "$ORG" ]] && { respond_error 400 "missing org parameter"; exit 0; }
[[ "$LIMIT" -gt 100 ]] && LIMIT=100

# GraphQL query — 1 API call for up to 100 repos
result="$(curl -sf \
  -H "Authorization: token $GH_TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.github.com/graphql" \
  -d "{\"query\":\"{ organization(login: \\\"${ORG}\\\") { repositories(first: ${LIMIT}, orderBy: {field: PUSHED_AT, direction: DESC}) { nodes { name description url isPrivate isArchived isFork pushedAt primaryLanguage { name } } pageInfo { hasNextPage } } } }\"}" \
  2>/dev/null || echo "{}")"

python3 - "$result" "$TYPE" << 'PYEOF'
import json, sys

raw, repo_type = sys.argv[1], sys.argv[2]
data = json.loads(raw)
nodes = data.get('data', {}).get('organization', {}).get('repositories', {}).get('nodes', [])

filtered = []
for r in nodes:
    if repo_type == 'public'  and r.get('isPrivate'):  continue
    if repo_type == 'private' and not r.get('isPrivate'): continue
    lang = r.get('primaryLanguage') or {}
    filtered.append({
        "name":        r.get('name'),
        "description": r.get('description'),
        "url":         r.get('url'),
        "private":     r.get('isPrivate'),
        "archived":    r.get('isArchived'),
        "fork":        r.get('isFork'),
        "pushed_at":   r.get('pushedAt'),
        "language":    lang.get('name')
    })

print(json.dumps({"org": sys.argv[2], "count": len(filtered), "repos": filtered}, indent=2))
PYEOF
