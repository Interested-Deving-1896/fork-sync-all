#!/usr/bin/env bash
# GET /api/fsa/codebase/drift
# Compares the current instance's HEAD SHA against all registered deployments.
# Shows which mirrors are behind, ahead, or in sync with the source.
#
# Query params:
#   ?deployment=all|<id>   — check specific deployment only (default: all)
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/fsa-adapter.sh"

DEPLOYMENT_FILTER="${QUERY_deployment:-all}"
DEPLOYMENTS_FILE="${_FSA_ROOT}/config/fsa-deployments.yml"

cd "$_FSA_ROOT" || { fsa_error "cannot cd to FSA root" 500; exit 0; }

fsa_quota_check 50 || exit 0

python3 - << PYEOF
import yaml, json, os, sys, subprocess, urllib.request, urllib.error
from datetime import datetime, timezone

gh_token     = '${GH_TOKEN}'
gitlab_token = os.environ.get('GITLAB_TOKEN', '')
dep_filter   = '${DEPLOYMENT_FILTER}'
repo_root    = '${_FSA_ROOT}'

def run(cmd, default=''):
    try:
        return subprocess.check_output(cmd, shell=True, stderr=subprocess.DEVNULL, text=True).strip()
    except Exception:
        return default

# Local state
local_sha    = run('git rev-parse HEAD')
local_branch = run('git rev-parse --abbrev-ref HEAD')

with open('${DEPLOYMENTS_FILE}') as f:
    cfg = yaml.safe_load(f) or {}

deployments = [d for d in cfg.get('deployments', []) if d.get('enabled', True)]
if dep_filter != 'all':
    deployments = [d for d in deployments if d.get('id') == dep_filter]

def gh_get(path, token, host=''):
    api = host.replace('https://github.com', 'https://api.github.com') if host else 'https://api.github.com'
    if api == 'https://github.com': api = 'https://api.github.com'
    req = urllib.request.Request(f"{api}{path}", headers={
        'Authorization': f'token {token}',
        'Accept': 'application/vnd.github+json',
    })
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read())

def gl_get(path, token, gl_host='https://gitlab.com'):
    req = urllib.request.Request(f"{gl_host}/api/v4{path}", headers={
        'PRIVATE-TOKEN': token,
        'Accept': 'application/json',
    })
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read())

results = []
for dep in deployments:
    dep_id   = dep.get('id')
    platform = dep.get('platform', 'github')
    org      = dep.get('org', '')
    repo     = dep.get('repo', 'fork-sync-all')
    host     = dep.get('host', '')
    group_path = dep.get('group_path', org)

    entry = {
        'id':       dep_id,
        'platform': platform,
        'org':      org,
        'position': dep.get('position'),
        'local_sha': local_sha,
        'remote_sha': None,
        'in_sync': None,
        'pushed_at': None,
        'error': None,
    }

    # Mark self
    is_self = (dep_id == 'source' and
               os.environ.get('GITHUB_REPOSITORY', '').endswith('/fork-sync-all') and
               os.environ.get('GITHUB_REPOSITORY_OWNER', '') == org)
    if is_self:
        entry['remote_sha'] = local_sha
        entry['in_sync'] = True
        entry['note'] = 'self'
        results.append(entry)
        continue

    try:
        if platform == 'github':
            data = gh_get(f'/repos/{org}/{repo}/commits/HEAD', gh_token, host)
            entry['remote_sha'] = data.get('sha', '')
            entry['pushed_at']  = data.get('commit', {}).get('committer', {}).get('date', '')
            entry['in_sync']    = entry['remote_sha'] == local_sha
            entry['commit_msg'] = data.get('commit', {}).get('message', '').split('\n')[0]

        elif platform == 'gitlab':
            gl_host = host or 'https://gitlab.com'
            encoded = group_path.replace('/', '%2F')
            proj = gl_get(f'/projects/{encoded}%2F{repo}', gitlab_token, gl_host)
            project_id = proj['id']
            default_branch = proj.get('default_branch', 'main')
            commits = gl_get(f'/projects/{project_id}/repository/commits?ref_name={default_branch}&per_page=1', gitlab_token, gl_host)
            if commits:
                c = commits[0]
                entry['remote_sha'] = c.get('id', '')
                entry['pushed_at']  = c.get('committed_date', '')
                entry['in_sync']    = entry['remote_sha'] == local_sha
                entry['commit_msg'] = c.get('title', '')

    except Exception as e:
        entry['error'] = str(e)
        entry['in_sync'] = None

    results.append(entry)

in_sync_count = sum(1 for r in results if r.get('in_sync') is True)
drifted_count = sum(1 for r in results if r.get('in_sync') is False)

print(json.dumps({
    'ok': True,
    'local_sha': local_sha,
    'local_branch': local_branch,
    'checked_at': datetime.now(timezone.utc).isoformat(),
    'summary': {
        'total': len(results),
        'in_sync': in_sync_count,
        'drifted': drifted_count,
        'unknown': len(results) - in_sync_count - drifted_count,
    },
    'deployments': results,
}, indent=2))
PYEOF
