#!/usr/bin/env bash
# GET /api/fsa/deployments
# Lists all registered FSA deployments from config/fsa-deployments.yml.
# Optionally checks reachability of each instance's FSA-API or platform API.
#
# Query params:
#   ?check=false|true   — probe each deployment's platform API (default: false)
#   ?platform=all|github|gitlab|gitea|forgejo|codeberg
#   ?position=all|source|mirror
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/fsa-adapter.sh"

CHECK="${QUERY_check:-false}"
PLATFORM_FILTER="${QUERY_platform:-all}"
POSITION_FILTER="${QUERY_position:-all}"

DEPLOYMENTS_FILE="${_FSA_ROOT}/config/fsa-deployments.yml"
if [[ ! -f "$DEPLOYMENTS_FILE" ]]; then
  fsa_error "config/fsa-deployments.yml not found" 404
  exit 0
fi

python3 - << PYEOF
import yaml, json, os, sys, urllib.request, urllib.error

repo_root = '${_FSA_ROOT}'
check = '${CHECK}' == 'true'
platform_filter = '${PLATFORM_FILTER}'
position_filter = '${POSITION_FILTER}'
gh_token = '${GH_TOKEN}'
gitlab_token = os.environ.get('GITLAB_TOKEN', '')

with open('${DEPLOYMENTS_FILE}') as f:
    cfg = yaml.safe_load(f) or {}

deployments = cfg.get('deployments', [])
results = []

for d in deployments:
    if not d.get('enabled', True):
        continue
    if platform_filter != 'all' and d.get('platform') != platform_filter:
        continue
    if position_filter != 'all' and d.get('position') != position_filter:
        continue

    entry = {
        'id':           d.get('id'),
        'platform':     d.get('platform'),
        'host':         d.get('host', ''),
        'org':          d.get('org'),
        'group_path':   d.get('group_path', ''),
        'repo':         d.get('repo', 'fork-sync-all'),
        'position':     d.get('position'),
        'chain_depth':  d.get('chain_depth', 0),
        'fsa_api_url':  d.get('fsa_api_url', ''),
        'reachable':    None,
        'quota':        None,
    }

    if check:
        platform = d.get('platform', 'github')
        org = d.get('org', '')
        repo = d.get('repo', 'fork-sync-all')
        try:
            if platform == 'github':
                api = d.get('host', 'https://github.com').replace('https://github.com', 'https://api.github.com')
                if api == 'https://github.com': api = 'https://api.github.com'
                url = f"{api}/repos/{org}/{repo}"
                req = urllib.request.Request(url, headers={
                    'Authorization': f'token {gh_token}',
                    'Accept': 'application/vnd.github+json',
                })
                with urllib.request.urlopen(req, timeout=8) as r:
                    data = json.loads(r.read())
                entry['reachable'] = True
                entry['repo_url'] = data.get('html_url', '')

                # quota
                rl_req = urllib.request.Request(f"{api}/rate_limit", headers={
                    'Authorization': f'token {gh_token}',
                    'Accept': 'application/vnd.github+json',
                })
                with urllib.request.urlopen(rl_req, timeout=8) as r:
                    rl = json.loads(r.read())
                entry['quota'] = rl.get('resources', {}).get('core', {}).get('remaining')

            elif platform == 'gitlab':
                host = d.get('host', 'https://gitlab.com')
                api = f"{host}/api/v4"
                group_path = d.get('group_path', org)
                encoded = group_path.replace('/', '%2F')
                url = f"{api}/projects/{encoded}%2F{repo}"
                req = urllib.request.Request(url, headers={
                    'PRIVATE-TOKEN': gitlab_token,
                    'Accept': 'application/json',
                })
                with urllib.request.urlopen(req, timeout=8) as r:
                    data = json.loads(r.read())
                entry['reachable'] = True
                entry['repo_url'] = data.get('web_url', '')
        except Exception as e:
            entry['reachable'] = False
            entry['error'] = str(e)

    results.append(entry)

print(json.dumps({'ok': True, 'count': len(results), 'items': results}, indent=2))
PYEOF
