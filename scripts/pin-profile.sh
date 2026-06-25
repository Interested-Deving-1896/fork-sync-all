#!/usr/bin/env bash
# scripts/pin-profile.sh — GitHub profile pin management
#
# Reads config/fsa-pin.yml profile block. Fills the GitHub profile pin slots
# with the configured list first, then auto-fills remaining slots with top
# repos ranked by stars or recent activity.
#
# Uses GitHub GraphQL API:
#   - query: pinnableItems (to list available repos)
#   - mutation: updateUserPinnedItems (to set pins)
#
# Requires a token with `user` scope (GH_TOKEN or PROFILE_TOKEN).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/includes/gh-api.sh"

info() { echo "[pin-profile] $*" >&2; }
warn() { echo "[pin-profile][warn] $*" >&2; }
dry()  { echo "[pin-profile][dry-run] $*" >&2; }

PIN_CFG="$REPO_ROOT/config/fsa-pin.yml"
DRY_RUN="${DRY_RUN:-false}"
# Profile pinning needs user scope — prefer PROFILE_TOKEN, fall back to GH_TOKEN
PROFILE_TOKEN="${PROFILE_TOKEN:-${GH_TOKEN:-}}"

[[ -f "$PIN_CFG" ]] || { warn "config/fsa-pin.yml not found"; exit 0; }

enabled=$(python3 -c "
import yaml
with open('$PIN_CFG') as f: c = yaml.safe_load(f)
print(str(c.get('profile',{}).get('enabled', False)).lower())
" 2>/dev/null)

[[ "$enabled" == "true" ]] || { info "profile pinning disabled — skipping"; exit 0; }
[[ -n "$PROFILE_TOKEN" ]] || { warn "PROFILE_TOKEN / GH_TOKEN required for profile pinning"; exit 1; }

login=$(python3 -c "
import yaml
with open('$PIN_CFG') as f: c = yaml.safe_load(f)
print(c.get('profile',{}).get('login',''))
" 2>/dev/null)

max_slots=$(python3 -c "
import yaml
with open('$PIN_CFG') as f: c = yaml.safe_load(f)
print(c.get('profile',{}).get('auto_fill',{}).get('max_slots', 6))
" 2>/dev/null)

rank_by=$(python3 -c "
import yaml
with open('$PIN_CFG') as f: c = yaml.safe_load(f)
print(c.get('profile',{}).get('auto_fill',{}).get('rank_by','stars'))
" 2>/dev/null)

auto_fill_enabled=$(python3 -c "
import yaml
with open('$PIN_CFG') as f: c = yaml.safe_load(f)
print(str(c.get('profile',{}).get('auto_fill',{}).get('enabled', True)).lower())
" 2>/dev/null)

info "login: ${login}, max_slots: ${max_slots}, rank_by: ${rank_by}"

# ── Step 1: Resolve explicit pins to node IDs ─────────────────────────────────
explicit_pins=$(python3 -c "
import yaml, json
with open('$PIN_CFG') as f: c = yaml.safe_load(f)
pins = c.get('profile',{}).get('pinned',[]) or []
print(json.dumps(pins))
" 2>/dev/null)

# GraphQL: resolve repo node IDs for explicit pins
explicit_node_ids=$(python3 - "$explicit_pins" << 'PYEOF'
import json, sys, subprocess, os

pins = json.loads(sys.argv[1])
if not pins:
    print(json.dumps([]))
    sys.exit(0)

token = os.environ.get('PROFILE_TOKEN') or os.environ.get('GH_TOKEN', '')
gh_api = os.environ.get('GH_API', 'https://api.github.com')

# Build aliases for each repo
aliases = []
for i, pin in enumerate(pins):
    if pin.startswith('gist:'):
        gist_id = pin[5:]
        aliases.append(f'g{i}: node(id: "{gist_id}") {{ id }}')
    else:
        parts = pin.split('/')
        if len(parts) == 2:
            owner, repo = parts
            aliases.append(f'r{i}: repository(owner: "{owner}", name: "{repo}") {{ id }}')

if not aliases:
    print(json.dumps([]))
    sys.exit(0)

query = 'query { ' + ' '.join(aliases) + ' }'
result = subprocess.run(
    ['curl', '-sf', '-X', 'POST',
     '-H', f'Authorization: token {token}',
     '-H', 'Content-Type: application/json',
     f'{gh_api}/graphql',
     '-d', json.dumps({'query': query})],
    capture_output=True, text=True
)
try:
    data = json.loads(result.stdout).get('data', {})
    node_ids = [v['id'] for v in data.values() if v and 'id' in v]
    print(json.dumps(node_ids))
except Exception as e:
    print(f'[pin-profile] error resolving node IDs: {e}', file=sys.stderr)
    print(json.dumps([]))
PYEOF
)

info "explicit pin node IDs: $(echo "$explicit_node_ids" | python3 -c "import json,sys; ids=json.load(sys.stdin); print(f'{len(ids)} resolved')" 2>/dev/null)"

# ── Step 2: Auto-fill remaining slots ─────────────────────────────────────────
final_node_ids="$explicit_node_ids"

if [[ "$auto_fill_enabled" == "true" ]]; then
  exclude_forks=$(python3 -c "
import yaml
with open('$PIN_CFG') as f: c = yaml.safe_load(f)
print(str(c.get('profile',{}).get('auto_fill',{}).get('exclude_forks', True)).lower())
" 2>/dev/null)

  exclude_archived=$(python3 -c "
import yaml
with open('$PIN_CFG') as f: c = yaml.safe_load(f)
print(str(c.get('profile',{}).get('auto_fill',{}).get('exclude_archived', True)).lower())
" 2>/dev/null)

  exclude_repos=$(python3 -c "
import yaml, json
with open('$PIN_CFG') as f: c = yaml.safe_load(f)
print(json.dumps(c.get('profile',{}).get('auto_fill',{}).get('exclude_repos',[]) or []))
" 2>/dev/null)

  # GraphQL: fetch pinnable items for auto-fill
  final_node_ids=$(python3 - \
    "$explicit_node_ids" "$max_slots" "$rank_by" \
    "$exclude_forks" "$exclude_archived" "$exclude_repos" "$login" << 'PYEOF'
import json, sys, subprocess, os

explicit_ids_json, max_slots_s, rank_by, excl_forks_s, excl_arch_s, excl_repos_json, login = sys.argv[1:]
explicit_ids = json.loads(explicit_ids_json)
max_slots = int(max_slots_s)
excl_forks = excl_forks_s == 'true'
excl_arch = excl_arch_s == 'true'
excl_repos = json.loads(excl_repos_json)

remaining = max_slots - len(explicit_ids)
if remaining <= 0:
    print(json.dumps(explicit_ids[:max_slots]))
    sys.exit(0)

token = os.environ.get('PROFILE_TOKEN') or os.environ.get('GH_TOKEN', '')
gh_api = os.environ.get('GH_API', 'https://api.github.com')

query = '''
query($login: String!) {
  repositoryOwner(login: $login) {
    repositories(first: 100, orderBy: {field: STARGAZERS, direction: DESC}) {
      nodes {
        id
        name
        nameWithOwner
        isFork
        isArchived
        stargazerCount
        pushedAt
      }
    }
  }
}
'''

result = subprocess.run(
    ['curl', '-sf', '-X', 'POST',
     '-H', f'Authorization: token {token}',
     '-H', 'Content-Type: application/json',
     f'{gh_api}/graphql',
     '-d', json.dumps({'query': query, 'variables': {'login': login}})],
    capture_output=True, text=True
)

try:
    data = json.loads(result.stdout)
    nodes = data.get('data', {}).get('repositoryOwner', {}).get('repositories', {}).get('nodes', [])
except Exception:
    nodes = []

# Filter and rank
candidates = []
for n in nodes:
    if n.get('id') in explicit_ids:
        continue
    if excl_forks and n.get('isFork'):
        continue
    if excl_arch and n.get('isArchived'):
        continue
    if n.get('nameWithOwner') in excl_repos or n.get('name') in excl_repos:
        continue
    candidates.append(n)

if rank_by == 'pushed_at':
    candidates.sort(key=lambda x: x.get('pushedAt', ''), reverse=True)
elif rank_by == 'combined':
    candidates.sort(key=lambda x: (x.get('stargazerCount', 0), x.get('pushedAt', '')), reverse=True)
# default: already sorted by stars from GraphQL

auto_ids = [n['id'] for n in candidates[:remaining]]
final = explicit_ids + auto_ids
print(json.dumps(final[:max_slots]))
PYEOF
  )
fi

final_count=$(echo "$final_node_ids" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null)
info "final pin list: ${final_count} item(s)"

if [[ "$DRY_RUN" == "true" ]]; then
  dry "Would set ${final_count} profile pins for ${login}"
  echo "$final_node_ids" | python3 -c "import json,sys; [print(f'  {id}') for id in json.load(sys.stdin)]" >&2
  exit 0
fi

# ── Step 3: Apply via GraphQL mutation ────────────────────────────────────────
python3 - "$final_node_ids" "$login" << 'PYEOF'
import json, sys, subprocess, os

node_ids = json.loads(sys.argv[1])
login = sys.argv[2]
token = os.environ.get('PROFILE_TOKEN') or os.environ.get('GH_TOKEN', '')
gh_api = os.environ.get('GH_API', 'https://api.github.com')

if not node_ids:
    print('[pin-profile] no items to pin', file=sys.stderr)
    sys.exit(0)

# First get the user/org node ID
user_query = f'query {{ repositoryOwner(login: "{login}") {{ id }} }}'
user_result = subprocess.run(
    ['curl', '-sf', '-X', 'POST',
     '-H', f'Authorization: token {token}',
     '-H', 'Content-Type: application/json',
     f'{gh_api}/graphql',
     '-d', json.dumps({'query': user_query})],
    capture_output=True, text=True
)
user_id = json.loads(user_result.stdout).get('data', {}).get('repositoryOwner', {}).get('id', '')
if not user_id:
    print('[pin-profile] could not resolve user node ID', file=sys.stderr)
    sys.exit(1)

mutation = '''
mutation($userId: ID!, $itemIds: [ID!]!) {
  updateUserPinnedItems(input: {userId: $userId, itemIds: $itemIds}) {
    pinnedItems {
      totalCount
    }
  }
}
'''

result = subprocess.run(
    ['curl', '-sf', '-X', 'POST',
     '-H', f'Authorization: token {token}',
     '-H', 'Content-Type: application/json',
     f'{gh_api}/graphql',
     '-d', json.dumps({'query': mutation, 'variables': {'userId': user_id, 'itemIds': node_ids}})],
    capture_output=True, text=True
)

data = json.loads(result.stdout)
if 'errors' in data:
    print(f'[pin-profile] GraphQL errors: {data["errors"]}', file=sys.stderr)
    sys.exit(1)

count = data.get('data', {}).get('updateUserPinnedItems', {}).get('pinnedItems', {}).get('totalCount', '?')
print(f'[pin-profile] profile pins updated: {count} item(s) pinned for {login}', file=sys.stderr)
PYEOF
