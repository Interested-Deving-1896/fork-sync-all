#!/usr/bin/env bash
# GET /api/fsa/codebase/status
# Returns the current state of the FSA codebase on this instance:
#   - Current commit SHA + message + author + timestamp
#   - Branch name
#   - Dirty/clean working tree
#   - Ahead/behind relative to origin/main
#   - Last push timestamp
#   - Script + workflow + adapter counts
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/fsa-adapter.sh"

cd "$_FSA_ROOT" || { fsa_error "cannot cd to FSA root" 500; exit 0; }

python3 - << 'PYEOF'
import subprocess, json, os, sys
from datetime import datetime, timezone

def run(cmd, default=''):
    try:
        return subprocess.check_output(cmd, shell=True, stderr=subprocess.DEVNULL, text=True).strip()
    except Exception:
        return default

repo_root = os.environ.get('_FSA_ROOT', '.')
os.chdir(repo_root)

# Git state
sha         = run('git rev-parse HEAD')
sha_short   = run('git rev-parse --short HEAD')
branch      = run('git rev-parse --abbrev-ref HEAD')
commit_msg  = run('git log -1 --pretty=%s')
commit_author = run('git log -1 --pretty=%an')
commit_ts   = run('git log -1 --pretty=%cI')
dirty_files = run('git status --porcelain')
is_dirty    = bool(dirty_files.strip())
dirty_count = len([l for l in dirty_files.splitlines() if l.strip()])

# Ahead/behind origin/main
try:
    ab = run('git rev-list --left-right --count origin/main...HEAD')
    behind, ahead = (int(x) for x in ab.split())
except Exception:
    behind, ahead = 0, 0

# Remote URL
remote_url = run('git remote get-url origin')

# Codebase inventory
wf_count     = len([f for f in os.listdir('.github/workflows') if f.endswith(('.yml','.yaml'))]) if os.path.isdir('.github/workflows') else 0
script_count = int(run("find scripts -name '*.sh' | wc -l", '0'))
adapter_count = int(run("find fsa-api/core/adapters -name '*.sh' | wc -l", '0'))
uaa_adapter_count = int(run("find fsa-api/uaa/adapters -name '*.sh' | wc -l", '0'))

# FSA-API route count
route_count = 0
try:
    import yaml
    with open('fsa-api/config/fsa-routes.yml') as f:
        cfg = yaml.safe_load(f)
    route_count = len(cfg.get('routes', []))
    with open('fsa-api/uaa/config/routes.yml') as f:
        ucfg = yaml.safe_load(f)
    route_count += len(ucfg.get('routes', []))
except Exception:
    pass

result = {
    'ok': True,
    'sha': sha,
    'sha_short': sha_short,
    'branch': branch,
    'commit': {
        'message': commit_msg,
        'author': commit_author,
        'timestamp': commit_ts,
    },
    'remote_url': remote_url,
    'dirty': is_dirty,
    'dirty_file_count': dirty_count,
    'ahead': ahead,
    'behind': behind,
    'inventory': {
        'workflows': wf_count,
        'scripts': script_count,
        'fsa_adapters': adapter_count,
        'uaa_adapters': uaa_adapter_count,
        'api_routes': route_count,
    },
    'checked_at': datetime.now(timezone.utc).isoformat(),
}

print(json.dumps(result, indent=2))
PYEOF
