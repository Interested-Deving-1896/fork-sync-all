#!/usr/bin/env bash
# GET /api/fsa/workflows
# Lists all FSA workflows/pipelines with their schedule, last run status, and toggle state.
# Platform-aware: reads .github/workflows/ on GitHub, .gitlab-ci.yml jobs on GitLab,
# Gitea Actions on Gitea/Forgejo, and falls back to local file listing on others.
#
# Query params:
#   ?filter=enabled|disabled|all   (default: all)
#   ?tier=1|2|3|4                  (filter by priority tier, GitHub only)
#   ?name=<substring>              (filter by name)
#   ?platform=<platform>           (override detected platform)
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/fsa-adapter.sh"

FILTER="${QUERY_filter:-all}"
TIER_FILTER="${QUERY_tier:-}"
NAME_FILTER="${QUERY_name:-}"
PLATFORM_OVERRIDE="${QUERY_platform:-}"

# Re-init platform if override requested
if [[ -n "$PLATFORM_OVERRIDE" ]]; then
  fsa_platform_init "$PLATFORM_OVERRIDE"
fi

ACTIVE_PLATFORM="${PA_PLATFORM:-github}"

# ── GitLab: list .gitlab-ci.yml jobs ─────────────────────────────────────────
if [[ "$ACTIVE_PLATFORM" == "gitlab" ]]; then
  gitlab_host="${PA_HOST:-https://gitlab.com}"
  gitlab_token="${GITLAB_TOKEN:-}"
  group_path="${FSA_GITLAB_GROUP:-openos-project/ops}"
  repo="${FSA_REPO##*/}"
  python3 - << GLEOF
import yaml, json, os, urllib.request

gl_host = '${gitlab_host}'
token   = '${gitlab_token}'
group   = '${group_path}'
repo    = '${repo}'
name_f  = '${NAME_FILTER}'.lower()

# Fetch .gitlab-ci.yml via API
encoded = group.replace('/', '%2F')
try:
    req = urllib.request.Request(
        f"{gl_host}/api/v4/projects/{encoded}%2F{repo}/repository/files/.gitlab-ci.yml/raw?ref=main",
        headers={'PRIVATE-TOKEN': token})
    with urllib.request.urlopen(req, timeout=10) as r:
        ci_content = r.read().decode()
    ci = yaml.safe_load(ci_content) or {}
except Exception as e:
    print(json.dumps({'ok': False, 'error': str(e)}))
    import sys; sys.exit(0)

items = []
for job_name, job_def in ci.items():
    if job_name.startswith('.') or not isinstance(job_def, dict):
        continue
    if name_f and name_f not in job_name.lower():
        continue
    items.append({
        'name': job_name,
        'stage': job_def.get('stage', ''),
        'rules': bool(job_def.get('rules') or job_def.get('only')),
        'manual': job_def.get('when') == 'manual',
        'platform': 'gitlab',
    })

print(json.dumps({'ok': True, 'platform': 'gitlab', 'count': len(items), 'items': items}, indent=2))
GLEOF
  exit 0
fi

# ── Gitea / Forgejo: list Actions workflows ───────────────────────────────────
if [[ "$ACTIVE_PLATFORM" == "gitea" || "$ACTIVE_PLATFORM" == "forgejo" ]]; then
  gitea_host="${PA_HOST:-}"
  gitea_token="${GITEA_TOKEN:-${FORGEJO_TOKEN:-}}"
  gitea_org="${FSA_ORG:-}"
  gitea_repo="${FSA_REPO##*/}"
  python3 - << GTEOF
import json, urllib.request

host  = '${gitea_host}'
token = '${gitea_token}'
org   = '${gitea_org}'
repo  = '${gitea_repo}'
name_f = '${NAME_FILTER}'.lower()

try:
    req = urllib.request.Request(
        f"{host}/api/v1/repos/{org}/{repo}/actions/workflows",
        headers={'Authorization': f'token {token}', 'Accept': 'application/json'})
    with urllib.request.urlopen(req, timeout=10) as r:
        data = json.loads(r.read())
    items = []
    for wf in data.get('workflows', []):
        if name_f and name_f not in wf.get('name','').lower():
            continue
        items.append({
            'name':  wf.get('name'),
            'file':  wf.get('path','').split('/')[-1],
            'state': wf.get('state'),
            'platform': '${ACTIVE_PLATFORM}',
        })
    print(json.dumps({'ok': True, 'platform': '${ACTIVE_PLATFORM}', 'count': len(items), 'items': items}, indent=2))
except Exception as e:
    print(json.dumps({'ok': False, 'error': str(e)}))
GTEOF
  exit 0
fi

# ── GitHub (default): existing implementation ─────────────────────────────────
fsa_quota_check 100 || exit 0

# Fetch last run for each workflow via GraphQL (1 API call)
runs_json=$(fsa_graphql "
{
  repository(owner: \"${FSA_ORG}\", name: \"${FSA_REPO##*/}\") {
    object(expression: \"HEAD:.github/workflows\") {
      ... on Tree {
        entries { name }
      }
    }
  }
}" 2>/dev/null)

# Read workflow files + priority tiers + toggles
python3 - << PYEOF
import yaml, os, json, sys

repo_root = '${_FSA_ROOT}'
workflows_dir = os.path.join(repo_root, '.github/workflows')
tiers_file = os.path.join(repo_root, 'config/workflow-priority-tiers.yml')
toggles_file = os.path.join(repo_root, 'fsa-api/config/fsa-toggles.yml')

# Load tiers
tiers = {}
try:
    with open(tiers_file) as f:
        cfg = yaml.safe_load(f)
    for w in cfg.get('workflows', []):
        tiers[w['name']] = w.get('tier', cfg.get('default_tier', 3))
    default_tier = cfg.get('default_tier', 3)
except Exception:
    default_tier = 3

# Load toggles
toggles = {}
try:
    with open(toggles_file) as f:
        cfg = yaml.safe_load(f)
    toggles = cfg.get('toggles', {})
except Exception:
    pass

results = []
for fname in sorted(os.listdir(workflows_dir)):
    if not fname.endswith(('.yml', '.yaml')):
        continue
    path = os.path.join(workflows_dir, fname)
    try:
        with open(path) as f:
            d = yaml.safe_load(f)
        if not isinstance(d, dict):
            continue
        name = d.get('name', fname)
        on = d.get(True, d.get('on', {})) or {}
        if isinstance(on, str):
            on = {on: {}}
        triggers = list(on.keys())
        schedules = [s.get('cron', '') for s in (on.get('schedule') or [])]
        has_dispatch = 'workflow_dispatch' in triggers
        wr_upstreams = []
        wr = on.get('workflow_run', {}) or {}
        if isinstance(wr, dict):
            wr_upstreams = wr.get('workflows', [])

        tier = tiers.get(name, default_tier)
        toggle = toggles.get(fname, toggles.get(name, {}))
        enabled = toggle.get('enabled', True) if isinstance(toggle, dict) else True

        # Apply filters
        filter_val = '${FILTER}'
        if filter_val == 'enabled' and not enabled:
            continue
        if filter_val == 'disabled' and enabled:
            continue
        tier_filter = '${TIER_FILTER}'
        if tier_filter and str(tier) != tier_filter:
            continue
        name_filter = '${NAME_FILTER}'.lower()
        if name_filter and name_filter not in name.lower() and name_filter not in fname.lower():
            continue

        results.append({
            'file': fname,
            'name': name,
            'tier': tier,
            'enabled': enabled,
            'triggers': triggers,
            'schedules': schedules,
            'has_dispatch': has_dispatch,
            'workflow_run_upstreams': wr_upstreams,
        })
    except Exception as e:
        pass

print(json.dumps({'ok': True, 'count': len(results), 'items': results}, indent=2))
PYEOF
