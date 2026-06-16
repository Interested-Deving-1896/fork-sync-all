#!/usr/bin/env bash
#
# scripts/check-ci.sh — agnostic CI status checker
#
# Checks the CI status of the default-branch HEAD for every repo in a given
# org/group, across any supported platform. Replaces check-osp-ci.sh and
# check-ooc-ci.sh with a single configurable engine.
#
# Outputs a JSON array of failing repos to stdout:
#   [{"repo":"name","sha":"abc123","url":"https://...","failures":["job1"]}, ...]
#
# Required env vars:
#   PLATFORM       — github | gitlab (more via platform-adapter.sh)
#   TARGET_ORG     — org/group name on the platform
#   TOKEN          — API token (PAT for GitHub, personal/project token for GitLab)
#
# Optional env vars:
#   SUBGROUPS_CONFIG — path to subgroups YAML for repo enumeration
#                      (default: config/gitlab-subgroups.yml for github platform)
#   REPO_FILTER    — optional substring filter on repo name
#   API_URL        — base API URL (default: platform canonical URL)
#   BUDGET_MINUTES — time budget (default: 25)
#   MIN_QUOTA      — skip if GitHub quota below this (default: 500, GitHub only)
#   TARGET_ID      — human-readable label for logs (default: PLATFORM/TARGET_ORG)
#   GH_TOKEN       — alias for TOKEN when PLATFORM=github (for includes compat)

set -uo pipefail

PLATFORM="${PLATFORM:?PLATFORM is required (github|gitlab)}"
TARGET_ORG="${TARGET_ORG:?TARGET_ORG is required}"
TOKEN="${TOKEN:-${GH_TOKEN:-}}"
: "${TOKEN:?TOKEN (or GH_TOKEN) is required}"

REPO_FILTER="${REPO_FILTER:-}"
BUDGET_MINUTES="${BUDGET_MINUTES:-25}"
MIN_QUOTA="${MIN_QUOTA:-500}"
TARGET_ID="${TARGET_ID:-${PLATFORM}/${TARGET_ORG}}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Logging ───────────────────────────────────────────────────────────────────
info() { echo "[check-ci:${TARGET_ID}] $*" >&2; }
warn() { echo "[check-ci:${TARGET_ID}] ⚠  $*" >&2; }
ok()   { echo "[check-ci:${TARGET_ID}] ✓ $*" >&2; }

# ── Platform defaults ─────────────────────────────────────────────────────────
case "$PLATFORM" in
  github)
    API_URL="${API_URL:-https://api.github.com}"
    GH_TOKEN="$TOKEN"
    export GH_TOKEN
    SUBGROUPS_CONFIG="${SUBGROUPS_CONFIG:-${REPO_ROOT}/config/gitlab-subgroups.yml}"
    ;;
  gitlab)
    API_URL="${API_URL:-https://gitlab.com}"
    SUBGROUPS_CONFIG="${SUBGROUPS_CONFIG:-${REPO_ROOT}/config/gitlab-subgroups.yml}"
    ;;
  *)
    warn "Unsupported platform '${PLATFORM}'. Supported: github, gitlab"
    echo "[]"
    exit 1
    ;;
esac

# ── Budget + API helpers (GitHub only) ────────────────────────────────────────
if [[ "$PLATFORM" == "github" ]]; then
  source "${SCRIPT_DIR}/includes/budget.sh"
  source "${SCRIPT_DIR}/includes/gh-api.sh"
  budget_init

  _quota_json=$(curl -sf \
    -H "Authorization: token ${TOKEN}" \
    "${API_URL}/rate_limit" 2>/dev/null || echo '{}')
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
  info "Quota: ${_quota_remaining} remaining"
fi

# ── Repo list ─────────────────────────────────────────────────────────────────
_load_repos_from_config() {
  local config="$1"
  python3 - <<PYEOF
import yaml, sys
data = yaml.safe_load(open("${config}"))
repos = []
for sg in (data.get("subgroups") or {}).values():
    repos.extend(sg.get("repos") or [])
for r in sorted(set(repos)):
    print(r)
PYEOF
}

_enumerate_github_org() {
  local owner="$1"
  local cursor=""
  while true; do
    local after_arg=""
    [[ -n "$cursor" ]] && after_arg=", after: \\\"${cursor}\\\""
    local result
    result=$(curl -sf \
      -H "Authorization: token ${TOKEN}" \
      -H "Content-Type: application/json" \
      "${API_URL}/graphql" \
      -d "{\"query\":\"{ organization(login: \\\"${owner}\\\") { repositories(first: 100${after_arg}) { nodes { name } pageInfo { hasNextPage endCursor } } } }\"}" \
      2>/dev/null || echo "{}")
    echo "$result" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for n in d.get('data',{}).get('organization',{}).get('repositories',{}).get('nodes',[]):
    print(n['name'])
" 2>/dev/null || true
    local has_next
    has_next=$(echo "$result" | python3 -c "
import json,sys
d=json.load(sys.stdin)
pi=d.get('data',{}).get('organization',{}).get('repositories',{}).get('pageInfo',{})
print('true' if pi.get('hasNextPage') else 'false')
" 2>/dev/null || echo "false")
    [[ "$has_next" != "true" ]] && break
    cursor=$(echo "$result" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d.get('data',{}).get('organization',{}).get('repositories',{}).get('pageInfo',{}).get('endCursor',''))
" 2>/dev/null || echo "")
  done
}

_enumerate_gitlab_group() {
  local group="$1"
  local page=1
  while true; do
    local result
    result=$(curl -sf \
      -H "Authorization: Bearer ${TOKEN}" \
      "${API_URL}/api/v4/groups/${group}/projects?per_page=100&page=${page}&include_subgroups=true" \
      2>/dev/null || echo "[]")
    local count
    count=$(echo "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); [print(p['path']) for p in d]" 2>/dev/null | wc -l || echo 0)
    echo "$result" | python3 -c "
import json,sys
for p in json.load(sys.stdin):
    print(p['path'])
" 2>/dev/null || true
    (( count < 100 )) && break
    (( page++ ))
  done
}

# Load repo list: config file first, fall back to org enumeration
mapfile -t REPOS < <(
  if [[ -f "$SUBGROUPS_CONFIG" ]]; then
    _load_repos_from_config "$SUBGROUPS_CONFIG"
  fi
)

if [[ "${#REPOS[@]}" -eq 0 ]]; then
  info "No repos in ${SUBGROUPS_CONFIG} — enumerating ${TARGET_ORG} via API..."
  if [[ "$PLATFORM" == "github" ]]; then
    mapfile -t REPOS < <(_enumerate_github_org "$TARGET_ORG")
  elif [[ "$PLATFORM" == "gitlab" ]]; then
    mapfile -t REPOS < <(_enumerate_gitlab_group "$TARGET_ORG")
  fi
fi

info "Repos to check: ${#REPOS[@]}"

# ── GitHub: GraphQL prefetch branch + SHA ─────────────────────────────────────
declare -A _BRANCH_CACHE=()
declare -A _SHA_CACHE=()

_prefetch_github_metadata() {
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
      -H "Authorization: token ${TOKEN}" \
      -H "Content-Type: application/json" \
      "${API_URL}/graphql" \
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

if [[ "$PLATFORM" == "github" && "${#REPOS[@]}" -gt 0 ]]; then
  info "Prefetching branch + SHA for ${#REPOS[@]} repos via GraphQL…"
  while IFS=$'\t' read -r _repo _branch _sha; do
    _BRANCH_CACHE["$_repo"]="$_branch"
    _SHA_CACHE["$_repo"]="$_sha"
  done < <(_prefetch_github_metadata "$TARGET_ORG" "${REPOS[@]}")
  info "Prefetch complete (${#_BRANCH_CACHE[@]} repos resolved)"
fi

# ── Check CI per repo ─────────────────────────────────────────────────────────
failing_repos="[]"
checked=0
skipped=0

_check_github_repo() {
  local repo="$1"
  local full_repo="${TARGET_ORG}/${repo}"

  local default_branch="${_BRANCH_CACHE[$repo]:-main}"
  local sha="${_SHA_CACHE[$repo]:-}"

  if [[ -z "$sha" ]]; then
    (( skipped++ )) || true
    return
  fi
  (( checked++ )) || true

  local checks_json
  checks_json=$(gh_get "${API_URL}/repos/${full_repo}/commits/${sha}/check-runs?per_page=100") || checks_json="{}"
  local failing_checks
  failing_checks=$(echo "$checks_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
runs = data.get('check_runs', [])
bad = [r['name'] for r in runs
       if r.get('conclusion') in ('failure','action_required','timed_out','cancelled')
       and r.get('status') == 'completed']
print(json.dumps(bad))
" 2>/dev/null || echo "[]")

  local statuses_json
  statuses_json=$(gh_get "${API_URL}/repos/${full_repo}/commits/${sha}/statuses?per_page=100") || statuses_json="[]"
  local failing_statuses
  failing_statuses=$(echo "$statuses_json" | python3 -c "
import json, sys
statuses = json.load(sys.stdin)
seen = {}
for s in statuses:
    ctx = s.get('context','')
    if ctx not in seen:
        seen[ctx] = s.get('state','')
bad = [ctx for ctx, state in seen.items() if state in ('failure','error')]
print(json.dumps(bad))
" 2>/dev/null || echo "[]")

  local all_failures
  all_failures=$(python3 -c "
import json
a = json.loads('${failing_checks}')
b = json.loads('${failing_statuses}')
print(json.dumps(sorted(set(a + b))))
" 2>/dev/null || echo "[]")

  local failure_count
  failure_count=$(echo "$all_failures" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
  local commit_url="https://github.com/${full_repo}/commit/${sha}"

  if (( failure_count > 0 )); then
    warn "${full_repo}: ${failure_count} failure(s) on ${sha:0:7}"
    failing_repos=$(echo "$failing_repos" | python3 -c "
import json, sys
lst = json.load(sys.stdin)
lst.append({
  'repo':      '${repo}',
  'full_repo': '${full_repo}',
  'platform':  'github',
  'branch':    '${default_branch}',
  'sha':       '${sha}',
  'sha_short': '${sha:0:7}',
  'url':       '${commit_url}',
  'failures':  json.loads('''${all_failures}''')
})
print(json.dumps(lst))
" 2>/dev/null || echo "$failing_repos")
  else
    ok "${full_repo}: green on ${sha:0:7}"
  fi
}

_check_gitlab_repo() {
  local repo="$1"
  local group_path="${TARGET_ORG}/${repo}"
  local encoded_path
  encoded_path=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${group_path}', safe=''))")

  # Get default branch + latest pipeline
  local project_json
  project_json=$(curl -sf \
    -H "Authorization: Bearer ${TOKEN}" \
    "${API_URL}/api/v4/projects/${encoded_path}" \
    2>/dev/null || echo "{}")

  local default_branch
  default_branch=$(echo "$project_json" | python3 -c \
    "import json,sys; print(json.load(sys.stdin).get('default_branch','main'))" 2>/dev/null || echo "main")

  local pipelines_json
  pipelines_json=$(curl -sf \
    -H "Authorization: Bearer ${TOKEN}" \
    "${API_URL}/api/v4/projects/${encoded_path}/pipelines?ref=${default_branch}&per_page=1" \
    2>/dev/null || echo "[]")

  local pipeline_status sha commit_url
  pipeline_status=$(echo "$pipelines_json" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(d[0].get('status','unknown') if d else 'no_pipeline')" \
    2>/dev/null || echo "unknown")
  sha=$(echo "$pipelines_json" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(d[0].get('sha','') if d else '')" \
    2>/dev/null || echo "")
  commit_url="${API_URL}/${group_path}/-/commit/${sha}"

  (( checked++ )) || true

  # failed, canceled, skipped are non-green; success/passed = green
  if [[ "$pipeline_status" =~ ^(failed|canceled)$ ]]; then
    warn "${group_path}: pipeline ${pipeline_status} on ${sha:0:7}"
    failing_repos=$(echo "$failing_repos" | python3 -c "
import json, sys
lst = json.load(sys.stdin)
lst.append({
  'repo':      '${repo}',
  'full_repo': '${group_path}',
  'platform':  'gitlab',
  'branch':    '${default_branch}',
  'sha':       '${sha}',
  'sha_short': '${sha:0:7}',
  'url':       '${commit_url}',
  'failures':  ['pipeline:${pipeline_status}']
})
print(json.dumps(lst))
" 2>/dev/null || echo "$failing_repos")
  else
    ok "${group_path}: ${pipeline_status} on ${sha:0:7}"
  fi
}

# ── Main loop ─────────────────────────────────────────────────────────────────
for repo in "${REPOS[@]}"; do
  [[ "$PLATFORM" == "github" ]] && { budget_check "$repo" || break; }

  if [[ -n "$REPO_FILTER" && "$repo" != *"$REPO_FILTER"* ]]; then
    continue
  fi

  case "$PLATFORM" in
    github) _check_github_repo "$repo" ;;
    gitlab) _check_gitlab_repo "$repo" ;;
  esac
done

info "Checked: ${checked} | Failing: $(echo "$failing_repos" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo '?') | Skipped: ${skipped}"

echo "$failing_repos"
