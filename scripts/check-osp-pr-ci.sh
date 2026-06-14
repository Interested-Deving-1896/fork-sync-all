#!/usr/bin/env bash
#
# Checks CI status on open PRs across all OSP-bound repos in
# Interested-Deving-1896 using GraphQL — one call per repo page.
#
# For each open PR, fetches the statusCheckRollup on the PR head commit.
# PRs with failing CI are surfaced so authors can be notified or the
# resolver can attempt a fix.
#
# Outputs a JSON array of failing PRs to stdout:
#   [{"repo":"name","pr":42,"title":"...","author":"...","branch":"feat/x",
#     "sha":"abc1234","state":"FAILURE","url":"https://...","contexts":["job"]}, ...]
#
# Required env vars:
#   GH_TOKEN       — PAT with repo scope (SYNC_TOKEN)
#   GITHUB_OWNER   — default: Interested-Deving-1896
#
# Optional env vars:
#   REPO_FILTER    — substring filter on repo name (blank = all)
#   BUDGET_MINUTES — time budget in minutes (default: 55)
#   MIN_QUOTA      — skip if quota below this (default: 500)

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"

OWNER="${GITHUB_OWNER:-Interested-Deving-1896}"
REPO_FILTER="${REPO_FILTER:-}"
MIN_QUOTA="${MIN_QUOTA:-500}"
GH_API="https://api.github.com"

# ── Logging ───────────────────────────────────────────────────────────────────
info() { echo "[check-osp-pr-ci] $*" >&2; }
warn() { echo "[check-osp-pr-ci] ⚠️  $*" >&2; }
ok()   { echo "[check-osp-pr-ci] ✓ $*" >&2; }

# ── Budget guard ──────────────────────────────────────────────────────────────
source "$(dirname "${BASH_SOURCE[0]}")/includes/budget.sh"
source "$(dirname "${BASH_SOURCE[0]}")/includes/gh-api.sh"
budget_init

# ── Quota pre-flight ──────────────────────────────────────────────────────────
_quota_remaining=$(curl -sf \
  -H "Authorization: token ${GH_TOKEN}" \
  "${GH_API}/rate_limit" 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('resources',{}).get('core',{}).get('remaining',0))" \
  2>/dev/null || echo 0)

if (( _quota_remaining < MIN_QUOTA )); then
  warn "Quota too low (${_quota_remaining} < ${MIN_QUOTA}) — skipping PR CI check."
  echo "[]"
  exit 0
fi
info "Quota: ${_quota_remaining} remaining"

# ── Load OSP-bound repo list ──────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG="${REPO_ROOT}/config/gitlab-subgroups.yml"

if [[ ! -f "$CONFIG" ]]; then
  warn "config/gitlab-subgroups.yml not found"
  echo "[]"
  exit 1
fi

mapfile -t OSP_REPOS < <(python3 - "$CONFIG" <<'PYEOF'
import yaml, sys
data = yaml.safe_load(open(sys.argv[1]))
repos = []
for sg in (data.get("subgroups") or {}).values():
    repos.extend(sg.get("repos") or [])
for r in sorted(set(repos)):
    print(r)
PYEOF
)

info "OSP-bound repos: ${#OSP_REPOS[@]}"

# ── GraphQL: fetch open PRs + head CI status per repo ────────────────────────
# Batches up to 10 repos per GraphQL call using aliases.
# Each alias fetches: open PRs (first 20) with head commit statusCheckRollup.
# 1 GraphQL call = 1 REST quota unit.

BATCH_SIZE=10
failing_prs="[]"
total_prs=0
total_failing=0
batch_num=0

for (( i=0; i<${#OSP_REPOS[@]}; i+=BATCH_SIZE )); do
  budget_check "batch-${batch_num}" || { warn "Budget exhausted"; break; }
  (( batch_num++ ))

  # Build alias slice
  batch=("${OSP_REPOS[@]:$i:$BATCH_SIZE}")

  # Apply repo filter — skip entire batch if no repos match
  filtered_batch=()
  for repo in "${batch[@]}"; do
    [[ -n "$REPO_FILTER" && "$repo" != *"$REPO_FILTER"* ]] && continue
    filtered_batch+=("$repo")
  done
  [[ ${#filtered_batch[@]} -eq 0 ]] && continue

  # Build GraphQL aliases
  aliases=$(python3 -c "
import sys, json
repos = json.loads(sys.argv[1])
owner = sys.argv[2]
parts = []
for i, repo in enumerate(repos):
    safe = repo.replace('-','_').replace('.','_')
    parts.append(
        f'r{i}: repository(owner: \"{owner}\", name: \"{repo}\") {{ '
        f'name '
        f'pullRequests(states: OPEN, first: 20, orderBy: {{field: UPDATED_AT, direction: DESC}}) {{ '
        f'nodes {{ '
        f'number title url author {{ login }} '
        f'headRefName '
        f'headCommit: commits(last: 1) {{ nodes {{ commit {{ oid statusCheckRollup {{ '
        f'state contexts(last: 20) {{ nodes {{ '
        f'... on CheckRun {{ name conclusion status }} '
        f'... on StatusContext {{ context state }} '
        f'}} }} }} }} }} }} '
        f'}} }} }}'
    )
print(' '.join(parts))
" "$(python3 -c "import json,sys; print(json.dumps(sys.argv[1:]))" "${filtered_batch[@]}")" "$OWNER")

  result=$(curl -sf \
    -H "Authorization: bearer ${GH_TOKEN}" \
    -H "Content-Type: application/json" \
    -X POST "${GH_API}/graphql" \
    -d "{\"query\":\"{ ${aliases} }\"}" \
    2>/dev/null || echo "{}")

  # Parse results
  while IFS=$'\t' read -r repo pr_num title author branch sha rollup_state contexts_json pr_url; do
    [[ -z "$repo" || -z "$pr_num" ]] && continue
    (( total_prs++ ))

    case "$rollup_state" in
      FAILURE|ERROR)
        warn "${OWNER}/${repo}#${pr_num}: CI ${rollup_state} on ${branch}@${sha:0:7} — ${pr_url}"
        (( total_failing++ ))

        failing_contexts=$(echo "$contexts_json" | python3 -c "
import json,sys
nodes=json.loads(sys.argv[1])
bad=[]
for n in nodes:
    if 'conclusion' in n:
        if n.get('conclusion') in ('FAILURE','ACTION_REQUIRED','TIMED_OUT','CANCELLED') \
           and n.get('status') == 'COMPLETED':
            bad.append(n.get('name','?'))
    elif 'context' in n:
        if n.get('state') in ('FAILURE','ERROR'):
            bad.append(n.get('context','?'))
print(json.dumps(bad))
" "$contexts_json" 2>/dev/null || echo "[]")

        failing_prs=$(echo "$failing_prs" | python3 -c "
import json,sys
lst=json.load(sys.stdin)
lst.append({
  'repo':     '${repo}',
  'owner':    '${OWNER}',
  'pr':       ${pr_num},
  'title':    '${title}',
  'author':   '${author}',
  'branch':   '${branch}',
  'sha':      '${sha:0:7}',
  'state':    '${rollup_state}',
  'url':      '${pr_url}',
  'contexts': json.loads('''${failing_contexts}''')
})
print(json.dumps(lst))
" 2>/dev/null || echo "$failing_prs")
        ;;
      SUCCESS|PENDING|EXPECTED|"")
        : # healthy or no CI
        ;;
    esac
  done < <(echo "$result" | python3 -c "
import json,sys
d=json.load(sys.stdin)
data=d.get('data',{})
for key,repo_data in data.items():
    if not repo_data: continue
    repo_name=repo_data.get('name','')
    prs=repo_data.get('pullRequests',{}).get('nodes',[])
    for pr in prs:
        pr_num=pr.get('number',0)
        title=pr.get('title','').replace(chr(9),' ').replace(chr(10),' ')
        pr_url=pr.get('url','')
        author=(pr.get('author') or {}).get('login','')
        branch=pr.get('headRefName','')
        commits=(pr.get('headCommit') or {}).get('nodes',[])
        if not commits: continue
        commit=commits[-1].get('commit',{})
        sha=commit.get('oid','')
        rollup=commit.get('statusCheckRollup') or {}
        state=rollup.get('state','')
        ctx_nodes=(rollup.get('contexts') or {}).get('nodes',[])
        print(f'{repo_name}\t{pr_num}\t{title}\t{author}\t{branch}\t{sha}\t{state}\t{json.dumps(ctx_nodes)}\t{pr_url}')
" 2>/dev/null)
done

info "Open PRs checked: ${total_prs} | Failing CI: ${total_failing} | GraphQL batches: ${batch_num}"

echo "$failing_prs"
