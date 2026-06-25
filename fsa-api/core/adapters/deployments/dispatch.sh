#!/usr/bin/env bash
# POST /api/fsa/deployments/:id/dispatch
# Triggers a workflow (GitHub Actions) or pipeline (GitLab CI) on a remote
# FSA deployment. Platform-aware: uses the correct dispatch mechanism per platform.
#
# Body (JSON):
#   {
#     "workflow": "sync-forks.yml",   -- workflow filename (GitHub) or pipeline ref (GitLab)
#     "ref":      "main",             -- branch/tag to run on
#     "inputs":   { "dry_run": true } -- workflow_dispatch inputs (GitHub) or variables (GitLab)
#   }
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/fsa-adapter.sh"

DEPLOYMENT_ID="${PATH_id:-}"
WORKFLOW="${BODY_workflow:-}"
REF="${BODY_ref:-main}"
INPUTS_JSON="${BODY_inputs:-{}}"

if [[ -z "$DEPLOYMENT_ID" ]]; then
  fsa_error "deployment id is required" 400; exit 0
fi
if [[ -z "$WORKFLOW" ]]; then
  fsa_error "workflow is required" 400; exit 0
fi

DEPLOYMENTS_FILE="${_FSA_ROOT}/config/fsa-deployments.yml"
fsa_quota_check 30 || exit 0

python3 - << PYEOF
import yaml, json, os, sys, urllib.request, urllib.error

dep_id     = '${DEPLOYMENT_ID}'
workflow   = '${WORKFLOW}'
ref        = '${REF}'
inputs_raw = '${INPUTS_JSON}'
gh_token   = '${GH_TOKEN}'
gitlab_token = os.environ.get('GITLAB_TOKEN', '')

try:
    inputs = json.loads(inputs_raw) if inputs_raw else {}
except Exception:
    inputs = {}

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

def do_request(url, data, headers, method='POST'):
    body = json.dumps(data).encode() if data else None
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}, r.status
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return json.loads(raw), e.code
        except Exception:
            return {'message': str(e)}, e.code

result = {'ok': False, 'deployment': dep_id, 'platform': platform, 'workflow': workflow}

if platform == 'github':
    api = host.replace('https://github.com', 'https://api.github.com') if host else 'https://api.github.com'
    if api == 'https://github.com': api = 'https://api.github.com'

    # Resolve workflow filename
    wf_file = workflow if workflow.endswith(('.yml', '.yaml')) else f'{workflow}.yml'
    url = f"{api}/repos/{org}/{repo}/actions/workflows/{wf_file}/dispatches"
    body = {'ref': ref, 'inputs': inputs}
    headers = {
        'Authorization': f'token {gh_token}',
        'Accept': 'application/vnd.github+json',
        'Content-Type': 'application/json',
    }
    resp, code = do_request(url, body, headers)
    if code in (204, 200):
        result['ok'] = True
        result['message'] = f'dispatched {wf_file} on {org}/{repo}@{ref}'
        result['dispatch_url'] = f"https://github.com/{org}/{repo}/actions"
    else:
        result['error'] = resp.get('message', f'HTTP {code}')
        result['code'] = code

elif platform == 'gitlab':
    gl_host = host or 'https://gitlab.com'
    # First resolve project ID
    encoded = group_path.replace('/', '%2F')
    proj_url = f"{gl_host}/api/v4/projects/{encoded}%2F{repo}"
    req = urllib.request.Request(proj_url, headers={'PRIVATE-TOKEN': gitlab_token})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            proj = json.loads(r.read())
        project_id = proj['id']
    except Exception as e:
        print(json.dumps({'ok': False, 'error': f'could not resolve GitLab project: {e}', 'code': 404}))
        sys.exit(0)

    # Trigger pipeline
    url = f"{gl_host}/api/v4/projects/{project_id}/pipeline"
    body = {'ref': ref, 'variables': [{'key': k, 'value': str(v)} for k, v in inputs.items()]}
    headers = {'PRIVATE-TOKEN': gitlab_token, 'Content-Type': 'application/json'}
    resp, code = do_request(url, body, headers)
    if code in (200, 201):
        result['ok'] = True
        result['pipeline_id'] = resp.get('id')
        result['pipeline_url'] = resp.get('web_url', '')
        result['message'] = f'triggered pipeline on {group_path}/{repo}@{ref}'
    else:
        result['error'] = resp.get('message', f'HTTP {code}')
        result['code'] = code

else:
    result['error'] = f'dispatch not yet implemented for platform: {platform}'
    result['code'] = 501

print(json.dumps(result, indent=2))
PYEOF
