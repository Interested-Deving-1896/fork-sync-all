#!/usr/bin/env bash
# GET /api/fsa/deployments/:id/workflows
# Lists workflows (GitHub Actions) or pipeline jobs (GitLab CI) on a remote
# FSA deployment. Platform-aware.
#
# Query params:
#   ?limit=N   (default: 20)
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/fsa-adapter.sh"

DEPLOYMENT_ID="${PATH_id:-}"
LIMIT="${QUERY_limit:-20}"

if [[ -z "$DEPLOYMENT_ID" ]]; then
  fsa_error "deployment id is required" 400; exit 0
fi

DEPLOYMENTS_FILE="${_FSA_ROOT}/config/fsa-deployments.yml"
fsa_quota_check 30 || exit 0

python3 - << PYEOF
import yaml, json, os, sys, urllib.request, urllib.error

dep_id     = '${DEPLOYMENT_ID}'
limit      = int('${LIMIT}') if '${LIMIT}'.isdigit() else 20
gh_token   = '${GH_TOKEN}'
gitlab_token = os.environ.get('GITLAB_TOKEN', '')

with open('${DEPLOYMENTS_FILE}') as f:
    cfg = yaml.safe_load(f) or {}

dep = next((d for d in cfg.get('deployments', []) if d.get('id') == dep_id), None)
if not dep:
    print(json.dumps({'ok': False, 'error': f'deployment not found: {dep_id}', 'code': 404}))
    sys.exit(0)

platform   = dep.get('platform', 'github')
org        = dep.get('org', '')
repo       = dep.get('repo', 'fork-sync-all')
host       = dep.get('host', '')
group_path = dep.get('group_path', org)

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

items = []
try:
    if platform == 'github':
        data = gh_get(f'/repos/{org}/{repo}/actions/workflows?per_page={limit}', gh_token)
        for wf in data.get('workflows', []):
            items.append({
                'id':           wf.get('id'),
                'name':         wf.get('name'),
                'file':         wf.get('path', '').split('/')[-1],
                'state':        wf.get('state'),
                'url':          wf.get('html_url'),
                'has_dispatch': True,  # can't tell without fetching each file; assume yes
            })

    elif platform == 'gitlab':
        gl_host = host or 'https://gitlab.com'
        encoded = group_path.replace('/', '%2F')
        proj = gl_get(f'/projects/{encoded}%2F{repo}', gitlab_token, gl_host)
        project_id = proj['id']
        # GitLab: list pipeline schedules as the closest equivalent
        schedules = gl_get(f'/projects/{project_id}/pipeline_schedules?per_page={limit}', gitlab_token, gl_host)
        for s in schedules:
            items.append({
                'id':       s.get('id'),
                'name':     s.get('description', ''),
                'ref':      s.get('ref'),
                'cron':     s.get('cron'),
                'active':   s.get('active'),
                'url':      f"{gl_host}/{group_path}/{repo}/-/pipeline_schedules",
            })
        # Also list recent pipelines as "workflow runs"
        pipelines = gl_get(f'/projects/{project_id}/pipelines?per_page={limit}', gitlab_token, gl_host)
        for p in pipelines:
            items.append({
                'pipeline_id': p.get('id'),
                'status':      p.get('status'),
                'ref':         p.get('ref'),
                'created_at':  p.get('created_at'),
                'url':         p.get('web_url'),
            })

    else:
        print(json.dumps({'ok': False, 'error': f'platform not yet supported: {platform}', 'code': 501}))
        sys.exit(0)

except Exception as e:
    print(json.dumps({'ok': False, 'error': str(e), 'code': 500}))
    sys.exit(0)

print(json.dumps({'ok': True, 'deployment': dep_id, 'platform': platform, 'count': len(items), 'items': items}, indent=2))
PYEOF
