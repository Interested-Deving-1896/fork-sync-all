#!/usr/bin/env bash
# GET /api/fsa/workflows
# Lists all FSA workflows with their schedule, last run status, and toggle state.
#
# Query params:
#   ?filter=enabled|disabled|all   (default: all)
#   ?tier=1|2|3|4                  (filter by priority tier)
#   ?name=<substring>              (filter by name)
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/fsa-adapter.sh"

FILTER="${QUERY_filter:-all}"
TIER_FILTER="${QUERY_tier:-}"
NAME_FILTER="${QUERY_name:-}"

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
