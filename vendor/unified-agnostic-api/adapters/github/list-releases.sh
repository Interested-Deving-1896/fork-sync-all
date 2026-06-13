#!/usr/bin/env bash
# adapters/github/list-releases.sh — list releases for a repo
# GET /api/github/releases/list?repo=owner/name&limit=10
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/lib/adapter.sh"

GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
[[ -z "$GH_TOKEN" ]] && { respond_error 500 "GH_TOKEN not set"; exit 0; }

REPO="$(query_param repo "")"
LIMIT="$(query_param limit "10")"
[[ -z "$REPO" ]] && { respond_error 400 "missing repo parameter (owner/name)"; exit 0; }

result="$(curl -sf \
  -H "Authorization: token $GH_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${REPO}/releases?per_page=${LIMIT}" \
  2>/dev/null || echo "[]")"

python3 - "$result" "$REPO" << 'PYEOF'
import json, sys
raw, repo = sys.argv[1], sys.argv[2]
releases = json.loads(raw)
out = []
for r in releases:
    out.append({
        "id":         r.get('id'),
        "tag":        r.get('tag_name'),
        "name":       r.get('name'),
        "draft":      r.get('draft'),
        "prerelease": r.get('prerelease'),
        "created_at": r.get('created_at'),
        "url":        r.get('html_url'),
        "assets":     len(r.get('assets', []))
    })
print(json.dumps({"repo": repo, "count": len(out), "releases": out}, indent=2))
PYEOF
