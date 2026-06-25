#!/usr/bin/env bash
# adapters/github/create-release.sh — create a GitHub release
# POST /api/github/releases/create
# Body: {"repo":"owner/name","tag":"v1.0.0","title":"...","body":"...","draft":false,"prerelease":false}
#
# Adapted from CadmusCJung/git-release-shell (curl-based release creation).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/lib/adapter.sh"

auth_check

GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
[[ -z "$GH_TOKEN" ]] && { respond_error 500 "GH_TOKEN not set"; exit 0; }

body="$(request_body)"
[[ -z "$body" ]] && { respond_error 400 "empty request body"; exit 0; }

tmp="$(mktemp)"
echo "$body" > "$tmp"

python3 - "$tmp" "$GH_TOKEN" << 'PYEOF'
import json, sys, urllib.request, urllib.error

tmp_file, token = sys.argv[1], sys.argv[2]
with open(tmp_file) as f:
    req = json.load(f)
import os; os.unlink(tmp_file)

repo       = req.get('repo', '')
tag        = req.get('tag', '')
title      = req.get('title', tag)
body_text  = req.get('body', '')
draft      = req.get('draft', False)
prerelease = req.get('prerelease', False)

if not repo or not tag:
    print(json.dumps({"error": "missing repo or tag"}))
    sys.exit(0)

payload = json.dumps({
    "tag_name":   tag,
    "name":       title,
    "body":       body_text,
    "draft":      draft,
    "prerelease": prerelease
}).encode()

url = f"https://api.github.com/repos/{repo}/releases"
request = urllib.request.Request(url, data=payload, method='POST')
request.add_header('Authorization', f'token {token}')
request.add_header('Content-Type', 'application/json')
request.add_header('Accept', 'application/vnd.github+json')

try:
    with urllib.request.urlopen(request) as resp:
        result = json.load(resp)
    print(json.dumps({
        "status": "created",
        "id":     result.get('id'),
        "url":    result.get('html_url'),
        "tag":    result.get('tag_name')
    }, indent=2))
except urllib.error.HTTPError as e:
    err = json.load(e)
    print(json.dumps({"error": err.get('message', str(e))}))
PYEOF
