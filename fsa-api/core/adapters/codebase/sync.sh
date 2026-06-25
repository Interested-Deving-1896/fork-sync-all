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
    # Dispatch sync-fsa-forks.yml on the source to push updates to this mirror
    # OR trigger a self-update via the existing ota-self-update.yml if available
    owner, repo = fsa_repo.split('/') if '/' in fsa_repo else ('Interested-Deving-1896', 'fork-sync-all')

    # Check if ota-self-update.yml exists (self-update path)
    self_update_wf = os.path.join(fsa_root, '.github/workflows/ota-self-update.yml')
    sync_fsa_wf    = os.path.join(fsa_root, '.github/workflows/sync-fsa-forks.yml')

    if dry_run:
        result['action'] = 'dry_run'
        result['message'] = f'Would dispatch sync workflow on {owner}/{repo}'
        result['would_dispatch'] = 'ota-self-update.yml' if os.path.exists(self_update_wf) else 'sync-fsa-forks.yml'
    else:
        wf_file = 'ota-self-update.yml' if os.path.exists(self_update_wf) else 'sync-fsa-forks.yml'
        url = f'https://api.github.com/repos/{owner}/{repo}/actions/workflows/{wf_file}/dispatches'
        body = json.dumps({'ref': 'main', 'inputs': {'force': str(force).lower()}}).encode()
        req = urllib.request.Request(url, data=body, headers={
            'Authorization': f'token {gh_token}',
            'Accept': 'application/vnd.github+json',
            'Content-Type': 'application/json',
        }, method='POST')
        try:
            with urllib.request.urlopen(req, timeout=15) as r:
                result['action'] = 'dispatched'
                result['workflow'] = wf_file
                result['message'] = f'Dispatched {wf_file} on {owner}/{repo}'
        except urllib.error.HTTPError as e:
            result['ok'] = False
            result['error'] = f'HTTP {e.code}: {e.read().decode()}'
else:
    result['action'] = 'none'
    result['message'] = f'Unknown node position: {node_position}'

print(json.dumps(result, indent=2))
PYEOF
