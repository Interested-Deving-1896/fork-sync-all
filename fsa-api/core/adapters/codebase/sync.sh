#!/usr/bin/env bash
# POST /api/fsa/codebase/sync
# Triggers a sync of this FSA instance's codebase from the source deployment.
# On the source instance: no-op (already authoritative).
# On GitHub mirrors: dispatches sync-fsa-forks.yml workflow_dispatch.
# On GitLab mirrors: triggers a pipeline on the mirror project.
#
# Body (JSON):
#   { "dry_run": false, "force": false }
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/fsa-adapter.sh"

DRY_RUN="${BODY_dry_run:-false}"
FORCE="${BODY_force:-false}"
DEPLOYMENTS_FILE="${_FSA_ROOT}/config/fsa-deployments.yml"

fsa_quota_check 30 || exit 0

# Detect which node we are
NODE_POSITION="${FSA_CHAIN_POSITION:-}"
if [[ -z "$NODE_POSITION" ]]; then
  REPO="${GITHUB_REPOSITORY:-}"
  if [[ "$REPO" == "Interested-Deving-1896/fork-sync-all" ]]; then
    NODE_POSITION="source"
  elif [[ -n "${FSA_UPSTREAM_OWNER:-}" ]]; then
    NODE_POSITION="mirror"
  else
    NODE_POSITION="downstream-fork"
  fi
fi

python3 - << PYEOF
import yaml, json, os, sys, urllib.request, urllib.error

dry_run       = '${DRY_RUN}' == 'true'
force         = '${FORCE}' == 'true'
node_position = '${NODE_POSITION}'
gh_token      = '${GH_TOKEN}'
gitlab_token  = os.environ.get('GITLAB_TOKEN', '')
fsa_repo      = '${FSA_REPO}'
fsa_root      = '${_FSA_ROOT}'

result = {
    'ok': True,
    'node_position': node_position,
    'dry_run': dry_run,
    'action': None,
    'message': None,
}

if node_position == 'source':
    result['action'] = 'none'
    result['message'] = 'This is the source instance — already authoritative. No sync needed.'

elif node_position in ('mirror', 'downstream-fork'):
    # Always dispatch on the SOURCE repo — sync-fsa-forks.yml and ota-self-update.yml
    # only exist there. Dispatching on a mirror repo would 404.
    # The source workflow then pushes the update to this mirror via fsa-forks.yml.
    owner, repo = 'Interested-Deving-1896', 'fork-sync-all'

    # Check if ota-self-update.yml exists (self-update path)
    self_update_wf = os.path.join(fsa_root, '.github/workflows/ota-self-update.yml')
    sync_fsa_wf    = os.path.join(fsa_root, '.github/workflows/sync-fsa-forks.yml')

    # Determine which workflow to dispatch:
    #   force=true  → critical-deploy-gitlab.yml (direct git push, bypasses mirror sync)
    #   normal      → ota-self-update.yml if present, else sync-fsa-forks.yml
    # sync-fsa-forks.yml handles all platforms (GitHub + GitLab) via platform-adapter.sh
    # and config/fsa-forks.yml, so it is the correct normal-path for all mirror types.
    if force:
        wf_file = 'critical-deploy-gitlab.yml'
        wf_inputs = {'push_to_gitlab': 'true', 'clear_pipelines': 'false',
                     'pause_schedules': 'false', 'resume_schedules': 'false',
                     'trigger_pipeline': 'true'}
    elif os.path.exists(self_update_wf):
        wf_file = 'ota-self-update.yml'
        wf_inputs = {'force': str(force).lower()}
    else:
        wf_file = 'sync-fsa-forks.yml'
        wf_inputs = {'dry_run': str(dry_run).lower()}

    if dry_run and not force:
        result['action'] = 'dry_run'
        result['message'] = f'Would dispatch {wf_file} on {owner}/{repo}'
        result['would_dispatch'] = wf_file
        result['would_inputs'] = wf_inputs
    else:
        url = f'https://api.github.com/repos/{owner}/{repo}/actions/workflows/{wf_file}/dispatches'
        body = json.dumps({'ref': 'main', 'inputs': wf_inputs}).encode()
        req = urllib.request.Request(url, data=body, headers={
            'Authorization': f'token {gh_token}',
            'Accept': 'application/vnd.github+json',
            'Content-Type': 'application/json',
        }, method='POST')
        try:
            with urllib.request.urlopen(req, timeout=15) as r:
                result['action'] = 'dispatched'
                result['workflow'] = wf_file
                result['inputs'] = wf_inputs
                result['message'] = f'Dispatched {wf_file} on {owner}/{repo}'
        except urllib.error.HTTPError as e:
            result['ok'] = False
            result['error'] = f'HTTP {e.code}: {e.read().decode()}'
else:
    result['action'] = 'none'
    result['message'] = f'Unknown node position: {node_position}'

print(json.dumps(result, indent=2))
PYEOF
