#!/usr/bin/env bash
#
# Checks the CI status of the default branch HEAD for ALL repos in
# Interested-Deving-1896 using a single GraphQL query per page.
#
# Uses the statusCheckRollup field on defaultBranchRef.target to fetch
# the combined CI state for every repo in one GraphQL call per 100 repos
# (~40-50 calls total for 4000+ repos vs ~12000 REST calls the naive way).
#
# Outputs a JSON array of failing repos to stdout:
#   [{"repo":"name","owner":"org","branch":"main","sha":"abc1234",
#     "state":"FAILURE","url":"https://...","contexts":["job1","job2"]}, ...]
#
# Required env vars:
#   GH_TOKEN       — PAT with repo scope (SYNC_TOKEN)
#
# Optional env vars:
#   GITHUB_OWNER   — org to scan (default: Interested-Deving-1896)
#   REPO_FILTER    — substring filter on repo name (blank = all)
#   BUDGET_MINUTES — time budget in minutes (default: 55)
#   SKIP_ARCHIVED  — skip archived repos (default: true)
#   SKIP_FORKS     — skip forked repos (default: false — forks are the point)
#   MIN_QUOTA      — skip if quota below this (default: 1000)

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"

OWNER="${GITHUB_OWNER:-Interested-Deving-1896}"
REPO_FILTER="${REPO_FILTER:-}"
SKIP_ARCHIVED="${SKIP_ARCHIVED:-true}"
SKIP_FORKS="${SKIP_FORKS:-false}"
MIN_QUOTA="${MIN_QUOTA:-1000}"
GH_API="https://api.github.com"

# ── Logging ───────────────────────────────────────────────────────────────────
info() { echo "[check-all-repos-ci] $*" >&2; }
warn() { echo "[check-all-repos-ci] ⚠️  $*" >&2; }
ok()   { echo "[check-all-repos-ci] ✓ $*" >&2; }

# ── Budget guard ──────────────────────────────────────────────────────────────
source "$(dirname "${BASH_SOURCE[0]}")/includes/budget.sh"
budget_init

# ── Quota pre-flight ──────────────────────────────────────────────────────────
_quota_json=$(curl -sf \
  -H "Authorization: token ${GH_TOKEN}" \
  "${GH_API}/rate_limit" 2>/dev/null || echo '{}')
_quota_remaining=$(echo "$_quota_json" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d.get('resources',{}).get('core',{}).get('remaining',0))" \
  2>/dev/null || echo 0)
_quota_reset=$(echo "$_quota_json" | python3 -c \
  "import sys,json,datetime; d=json.load(sys.stdin); \
   ts=d.get('resources',{}).get('core',{}).get('reset',0); \
   print(datetime.datetime.utcfromtimestamp(ts).strftime('%H:%M UTC') if ts else 'unknown')" \
  2>/dev/null || echo 'unknown')

if (( _quota_remaining < MIN_QUOTA )); then
  warn "Quota too low (${_quota_remaining} < ${MIN_QUOTA}) — resets at ${_quota_reset}. Skipping."
  echo "[]"
  exit 0
fi
info "Quota: ${_quota_remaining} remaining (resets ${_quota_reset})"

# ── GraphQL query ─────────────────────────────────────────────────────────────
# Fetches per page: name, isArchived, isFork, defaultBranchRef with
# statusCheckRollup (combined CI state + individual context names).
# One GraphQL call = 1 REST quota unit regardless of repos per page.

graphql_page() {
  local after_clause="$1"   # empty string or ', after: "CURSOR"'
  local skip_archived_clause=""
  [[ "$SKIP_ARCHIVED" == "true" ]] && skip_archived_clause=", isArchived: false"

  local query
  query=$(python3 -c "
import sys
after = sys.argv[1]
skip_archived = sys.argv[2]
q = '''{ organization(login: \"OWNER\") {
  repositories(first: 100AFTER SKIP_ARCHIVED, orderBy: {field: PUSHED_AT, direction: DESC}) {
    nodes {
      name
      isArchived
      isFork
      defaultBranchRef {
        name
        target {
          ... on Commit {
            oid
            statusCheckRollup {
              state
              contexts(last: 20) {
                nodes {
                  ... on CheckRun {
                    name
                    conclusion
                    status
                  }
                  ... on StatusContext {
                    context
                    state
                  }
                }
              }
            }
          }
        }
      }
    }
    pageInfo { hasNextPage endCursor }
  }
} }'''
q = q.replace('OWNER', 'PLACEHOLDER_OWNER')
q = q.replace('AFTER', after)
q = q.replace('SKIP_ARCHIVED', skip_archived)
# Collapse to single line for JSON embedding
q = ' '.join(q.split())
print(q)
" "$after_clause" "$skip_archived_clause" | sed "s/PLACEHOLDER_OWNER/${OWNER}/g")

  curl -sf \
    -H "Authorization: bearer ${GH_TOKEN}" \
    -H "Content-Type: application/json" \
    -X POST "${GH_API}/graphql" \
    -d "{\"query\":\"${query}\"}" \
    2>/dev/null || echo "{}"
}

# ── Paginate and collect failures ─────────────────────────────────────────────
failing_repos="[]"
cursor=""
page=0
total_repos=0
total_checked=0
total_no_ci=0

info "Scanning ${OWNER} repos via GraphQL statusCheckRollup..."

while true; do
  budget_check "page-${page}" || { warn "Budget exhausted after ${page} pages"; break; }

  after_clause=""
  [[ -n "$cursor" ]] && after_clause=", after: \\\"${cursor}\\\""

  result=$(graphql_page "$after_clause")

  # Extract nodes
  nodes_json=$(echo "$result" | python3 -c "
import json,sys
d=json.load(sys.stdin)
nodes=d.get('data',{}).get('organization',{}).get('repositories',{}).get('nodes',[])
print(json.dumps(nodes))
" 2>/dev/null || echo "[]")

  node_count=$(echo "$nodes_json" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)

  if (( node_count == 0 )); then
    [[ $page -eq 0 ]] && warn "GraphQL returned no repos — check token and org name"
    break
  fi

  (( page++ ))
  (( total_repos += node_count ))

  # Process each repo node
  while IFS=$'\t' read -r name is_archived is_fork branch sha rollup_state contexts_json; do
    [[ -z "$name" ]] && continue

    # Apply filters
    [[ "$SKIP_ARCHIVED" == "true" && "$is_archived" == "True" ]] && continue
    [[ "$SKIP_FORKS" == "true" && "$is_fork" == "True" ]] && continue
    [[ -n "$REPO_FILTER" && "$name" != *"$REPO_FILTER"* ]] && continue

    (( total_checked++ ))

    # No default branch or no CI data
    if [[ -z "$branch" || -z "$rollup_state" || "$rollup_state" == "None" ]]; then
      (( total_no_ci++ ))
      continue
    fi

    # FAILURE / ERROR are actionable; SUCCESS / PENDING / EXPECTED are not
    case "$rollup_state" in
      FAILURE|ERROR)
        repo_url="https://github.com/${OWNER}/${name}/commit/${sha}"
        warn "${OWNER}/${name}: CI ${rollup_state} on ${branch}@${sha:0:7}"

        # Extract failing context names
        failing_contexts=$(echo "$contexts_json" | python3 -c "
import json,sys
nodes=json.loads(sys.argv[1])
bad=[]
for n in nodes:
    # CheckRun
    if 'conclusion' in n:
        if n.get('conclusion') in ('FAILURE','ACTION_REQUIRED','TIMED_OUT','CANCELLED') \
           and n.get('status') == 'COMPLETED':
            bad.append(n.get('name','?'))
    # StatusContext
    elif 'context' in n:
        if n.get('state') in ('FAILURE','ERROR'):
            bad.append(n.get('context','?'))
print(json.dumps(bad))
" "$contexts_json" 2>/dev/null || echo "[]")

        failing_repos=$(echo "$failing_repos" | python3 -c "
import json,sys
lst=json.load(sys.stdin)
lst.append({
  'repo':     '${name}',
  'owner':    '${OWNER}',
  'branch':   '${branch}',
  'sha':      '${sha:0:7}',
  'state':    '${rollup_state}',
  'url':      '${repo_url}',
  'contexts': json.loads('''${failing_contexts}''')
})
print(json.dumps(lst))
" 2>/dev/null || echo "$failing_repos")
        ;;
      SUCCESS|PENDING|EXPECTED)
        : # healthy or in-progress — skip
        ;;
    esac
  done < <(echo "$nodes_json" | python3 -c "
import json,sys
nodes=json.load(sys.stdin)
for n in nodes:
    name        = n.get('name','')
    is_archived = str(n.get('isArchived', False))
    is_fork     = str(n.get('isFork', False))
    dbr         = n.get('defaultBranchRef') or {}
    branch      = dbr.get('name','')
    target      = dbr.get('target') or {}
    sha         = target.get('oid','')
    rollup      = target.get('statusCheckRollup') or {}
    state       = rollup.get('state','')
    ctx_nodes   = (rollup.get('contexts') or {}).get('nodes',[])
    print(f'{name}\t{is_archived}\t{is_fork}\t{branch}\t{sha}\t{state}\t{json.dumps(ctx_nodes)}')
" 2>/dev/null)

  # Pagination
  has_next=$(echo "$result" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d.get('data',{}).get('organization',{}).get('repositories',{}).get('pageInfo',{}).get('hasNextPage',False))
" 2>/dev/null || echo "False")

  [[ "$has_next" != "True" ]] && break

  cursor=$(echo "$result" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d.get('data',{}).get('organization',{}).get('repositories',{}).get('pageInfo',{}).get('endCursor',''))
" 2>/dev/null || echo "")

  [[ -z "$cursor" ]] && break
done

failing_count=$(echo "$failing_repos" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "?")
info "Pages: ${page} | Repos scanned: ${total_repos} | Checked: ${total_checked} | No CI: ${total_no_ci} | Failing: ${failing_count}"
info "GraphQL calls used: ${page} (vs ~$((total_repos * 3)) REST calls the naive way)"

echo "$failing_repos"
