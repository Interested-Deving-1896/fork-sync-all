#!/usr/bin/env bash
# GET /api/fsa/deployments/:id/status
# Returns the status of a specific FSA deployment:
#   - Platform API reachability
#   - Quota remaining
#   - FSA-API health (if fsa_api_url is set)
#   - Last workflow/pipeline run status
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/fsa-adapter.sh"

DEPLOYMENT_ID="${PATH_id:-}"
if [[ -z "$DEPLOYMENT_ID" ]]; then
  fsa_error "deployment id is required" 400
  exit 0
fi

DEPLOYMENTS_FILE="${_FSA_ROOT}/config/fsa-deployments.yml"

fsa_quota_check 30 || exit 0

python3 - << PYEOF
import yaml, json, os, sys, urllib.request, urllib.error

dep_id = '${DEPLOYMENT_ID}'
gh_token = '${GH_TOKEN}'
gitlab_token = os.environ.get('GITLAB_TOKEN', '')

with open('${DEPLOYMENTS_FILE}') as f:
    cfg = yaml.safe_load(f) or {}

dep = next((d for d in cfg.get('deployments', []) if d.get('id') == dep_id), None)
if not dep:
    print(json.dumps({'ok': False, 'error': f'deployment not found: {dep_id}', 'code': 404}))
    sys.exit(0)

platform = dep.get('platform', 'github')
org      = dep.get('org', '')
repo     = dep.get('repo', 'fork-sync-all')
host     = dep.get('host', '')
group_path = dep.get('group_path', org)

result = {
    'ok': True,
    'id': dep_id,
    'platform': platform,
    'org': org,
    'repo': repo,
    'position': dep.get('position'),
    'chain_depth': dep.get('chain_depth', 0),
    'reachable': False,
    'quota': None,
    'fsa_api_healthy': None,
    'last_run': None,
    'error': None,
}

def gh_get(path, token):
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

try:
    if platform == 'github':
        # Repo reachability
        data = gh_get(f'/repos/{org}/{repo}', gh_token)
        result['reachable'] = True
        result['repo_url'] = data.get('html_url', '')
        result['default_branch'] = data.get('default_branch', 'main')
        result['pushed_at'] = data.get('pushed_at', '')

        # Quota
        rl = gh_get('/rate_limit', gh_token)
        result['quota'] = rl.get('resources', {}).get('core', {}).get('remaining')

        # Last workflow run (any workflow)
        runs = gh_get(f'/repos/{org}/{repo}/actions/runs?per_page=1', gh_token)
        last = (runs.get('workflow_runs') or [{}])[0]
        if last:
            result['last_run'] = {
                'workflow': last.get('name'),
                'status': last.get('status'),
                'conclusion': last.get('conclusion'),
                'created_at': last.get('created_at'),
                'url': last.get('html_url'),
            }

    elif platform == 'gitlab':
        gl_host = host or 'https://gitlab.com'
        encoded = group_path.replace('/', '%2F')
        data = gl_get(f'/projects/{encoded}%2F{repo}', gitlab_token, gl_host)
        result['reachable'] = True
        result['repo_url'] = data.get('web_url', '')
        result['default_branch'] = data.get('default_branch', 'main')
        result['pushed_at'] = data.get('last_activity_at', '')
        project_id = data.get('id')

        # Last pipeline
        pipelines = gl_get(f'/projects/{project_id}/pipelines?per_page=1', gitlab_token, gl_host)
        if pipelines:
            p = pipelines[0]
            result['last_run'] = {
                'pipeline_id': p.get('id'),
                'status': p.get('status'),
                'ref': p.get('ref'),
                'created_at': p.get('created_at'),
                'url': p.get('web_url'),
            }

except Exception as e:
    result['reachable'] = False
    result['error'] = str(e)

# FSA-API health check (if configured)
fsa_api_url = dep.get('fsa_api_url', '')
if fsa_api_url:
    try:
        req = urllib.request.Request(f"{fsa_api_url}/health")
        with urllib.request.urlopen(req, timeout=5) as r:
            health = json.loads(r.read())
        result['fsa_api_healthy'] = health.get('status') == 'ok'
        result['fsa_api_version'] = health.get('version', '')
    except Exception as e:
        result['fsa_api_healthy'] = False
        result['fsa_api_error'] = str(e)

print(json.dumps(result, indent=2))
PYEOF
