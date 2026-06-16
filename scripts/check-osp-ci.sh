#!/usr/bin/env bash
#
# Checks the CI status of the default branch HEAD for every OSP-bound repo
# (derived from config/gitlab-subgroups.yml).
#
# For each repo, queries the GitHub Checks API and Commit Statuses API.
# A repo is considered failing if any check run or status context on the
# latest default-branch commit is in a failure/error/action_required state.
#
# Outputs a JSON array of failing repos to stdout:
#   [{"repo":"name","sha":"abc123","url":"https://...","failures":["job1"]}, ...]
#
# Required env vars:
#   GH_TOKEN       — PAT with repo scope (SYNC_TOKEN)
#   GITHUB_OWNER   — default: Interested-Deving-1896
#   REPO_FILTER    — optional substring filter on repo name
#
# Optional env vars:
#   BUDGET_MINUTES — time budget (default: 55)
#   MIN_QUOTA      — skip if quota below this (default: 500)

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"

OWNER="${GITHUB_OWNER:-Interested-Deving-1896}"
REPO_FILTER="${REPO_FILTER:-}"
API="https://api.github.com"

# ── Logging ───────────────────────────────────────────────────────────────────
info() { echo "[check-osp-ci] $*" >&2; }
warn() { echo "[check-osp-ci] ⚠️  $*" >&2; }
ok()   { echo "[check-osp-ci] ✓ $*" >&2; }

# ── Budget guard ──────────────────────────────────────────────────────────────
source "$(dirname "${BASH_SOURCE[0]}")/includes/budget.sh"
source "$(dirname "${BASH_SOURCE[0]}")/includes/gh-api.sh"
budget_init

# ── Quota pre-flight ──────────────────────────────────────────────────────────
MIN_QUOTA="${MIN_QUOTA:-500}"
_quota_json=$(curl -sf \
  -H "Authorization: token ${GH_TOKEN}" \
  "https://api.github.com/rate_limit" 2>/dev/null || echo '{}')
_quota_remaining=$(echo "$_quota_json" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d.get('resources',{}).get('core',{}).get('remaining',0))" \
  2>/dev/null || echo 0)
_quota_reset=$(echo "$_quota_json" | python3 -c \
  "import sys,json,datetime; d=json.load(sys.stdin); \
   ts=d.get('resources',{}).get('core',{}).get('reset',0); \
   print((lambda dt: dt.strftime('%H:%M UTC') + ' / ' + dt.strftime('%I:%M %p UTC').lstrip('0') or '12:00 AM UTC')(datetime.datetime.utcfromtimestamp(ts)) if ts else 'unknown')" \
  2>/dev/null || echo 'unknown')

if (( _quota_remaining < MIN_QUOTA )); then
  warn "Quota too low (${_quota_remaining} < ${MIN_QUOTA}) — resets at ${_quota_reset}. Skipping."
  echo "[]"
  exit 0
fi
info "Quota: ${_quota_remaining} remaining"

# ── GitHub API helper ─────────────────────────────────────────────────────────

# ── Load OSP-bound repo list ──────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG="${REPO_ROOT}/config/gitlab-subgroups.yml"

if [[ ! -f "$CONFIG" ]]; then
  warn "config/gitlab-subgroups.yml not found"
  echo "[]"
  exit 1
fi

mapfile -t OSP_REPOS < <(python3 - <<'PYEOF'
import yaml, sys
data = yaml.safe_load(open(sys.argv[1]))
repos = []
for sg in (data.get("subgroups") or {}).values():
    repos.extend(sg.get("repos") or [])
for r in sorted(set(repos)):
    print(r)
PYEOF
"$CONFIG")

info "OSP-bound repos: ${#OSP_REPOS[@]}"

# ── Prefetch default branch + HEAD SHA via GraphQL (1 call for all repos) ─────
# Replaces 2 REST calls per repo (GET /repos/{r} + GET /repos/{r}/branches/{b}).
# check-runs and statuses are not in GraphQL so those remain as REST calls.
declare -A _BRANCH_CACHE=()   # repo -> default_branch
declare -A _SHA_CACHE=()      # repo -> HEAD SHA

_prefetch_repo_metadata() {
  local owner="$1"; shift
  local repos=("$@")
  local total="${#repos[@]}"
  local page_size=100
  local offset=0

  while (( offset < total )); do
    local aliases=""
    local i
    for (( i=offset; i < offset+page_size && i < total; i++ )); do
      local r="${repos[$i]}"
      local safe
      safe=$(echo "$r" | tr '-' '_' | tr '.' '_')
      aliases+="r_${safe}: repository(owner: \"${owner}\", name: \"${r}\") { defaultBranchRef { name target { oid } } } "
    done

    local gql_result
    gql_result=$(curl -sf \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "Content-Type: application/json" \
      "${API}/graphql" \
      -d "{\"query\":\"{ ${aliases} }\"}" \
      2>/dev/null || echo "{}")

    python3 - <<PYEOF
import json, sys
result = json.loads('''${gql_result}''')
data = result.get("data") or {}
for key, val in data.items():
    if not val:
        continue
    repo_name = key[2:].replace("_", "-")
    ref = (val.get("defaultBranchRef") or {})
    branch = ref.get("name") or "main"
    sha = (ref.get("target") or {}).get("oid") or ""
    print(f"{repo_name}\t{branch}\t{sha}")
PYEOF

    (( offset += page_size ))
  done
}

info "Prefetching branch + SHA for ${#OSP_REPOS[@]} repos via GraphQL…"
while IFS=$'\t' read -r _repo _branch _sha; do
  _BRANCH_CACHE["$_repo"]="$_branch"
  _SHA_CACHE["$_repo"]="$_sha"
done < <(_prefetch_repo_metadata "$OWNER" "${OSP_REPOS[@]}")
info "Prefetch complete (${#_BRANCH_CACHE[@]} repos resolved)"

# ── Check CI status for each repo ─────────────────────────────────────────────
failing_repos="[]"
checked=0
skipped=0

for repo in "${OSP_REPOS[@]}"; do
  budget_check "$repo" || break

  # Apply optional name filter
  if [[ -n "$REPO_FILTER" && "$repo" != *"$REPO_FILTER"* ]]; then
    continue
  fi

  full_repo="${OWNER}/${repo}"

  # Use prefetched values — no REST calls for repo info or branch
  default_branch="${_BRANCH_CACHE[$repo]:-main}"
  sha="${_SHA_CACHE[$repo]:-}"

  if [[ -z "$sha" ]]; then
    # Repo not in GraphQL result (doesn't exist or has no commits)
    (( skipped++ ))
    continue
  fi

  (( checked++ ))

  # Collect failing check names from Checks API
  checks_json=$(gh_get "${API}/repos/${full_repo}/commits/${sha}/check-runs?per_page=100") || checks_json="{}"
  failing_checks=$(echo "$checks_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
runs = data.get('check_runs', [])
bad = [r['name'] for r in runs
       if r.get('conclusion') in ('failure','action_required','timed_out','cancelled')
       and r.get('status') == 'completed']
print(json.dumps(bad))
" 2>/dev/null || echo "[]")

  # Collect failing contexts from legacy Statuses API
  statuses_json=$(gh_get "${API}/repos/${full_repo}/commits/${sha}/statuses?per_page=100") || statuses_json="[]"
  failing_statuses=$(echo "$statuses_json" | python3 -c "
import json, sys
statuses = json.load(sys.stdin)
# Keep only the latest status per context
seen = {}
for s in statuses:
    ctx = s.get('context','')
    if ctx not in seen:
        seen[ctx] = s.get('state','')
bad = [ctx for ctx, state in seen.items() if state in ('failure','error')]
print(json.dumps(bad))
" 2>/dev/null || echo "[]")

  # Merge both lists
  all_failures=$(python3 -c "
import json, sys
a = json.loads('${failing_checks}')
b = json.loads('${failing_statuses}')
print(json.dumps(sorted(set(a + b))))
" 2>/dev/null || echo "[]")

  failure_count=$(echo "$all_failures" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)

  if (( failure_count > 0 )); then
    commit_url="https://github.com/${full_repo}/commit/${sha}"
    warn "${full_repo}: ${failure_count} failure(s) on ${sha:0:7} — ${commit_url}"
    failing_repos=$(echo "$failing_repos" | python3 -c "
import json, sys
lst = json.load(sys.stdin)
lst.append({
  'repo':     '${repo}',
  'full_repo':'${full_repo}',
  'branch':   '${default_branch}',
  'sha':      '${sha}',
  'sha_short':'${sha:0:7}',
  'url':      '${commit_url}',
  'failures': json.loads('''${all_failures}''')
})
print(json.dumps(lst))
" 2>/dev/null || echo "$failing_repos")
  else
    ok "${full_repo}: green on ${sha:0:7}"
  fi
done

info "Checked: ${checked} | Failing: $(echo "$failing_repos" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo '?') | Skipped: ${skipped}"

echo "$failing_repos"
