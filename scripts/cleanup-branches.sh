#!/usr/bin/env bash
#
# Cleans up stale branches across all repos in one or more GitHub orgs or user accounts.
#
# Strategy:
#   - Keep the default branch of each repo
#   - Keep branches matching KEEP_PATTERNS (protected, lts, etc.)
#   - Keep upstream-commits/* branches only if they have an open PR
#   - Delete all other branches that are fully merged into the default branch
#   - Optionally delete unmerged branches too (FORCE_DELETE=true)
#
# Required env vars:
#   GH_TOKEN   — PAT with repo + read:org scopes
#   ORGS       — space-separated list of orgs or user accounts to process
#
# Optional env vars:
#   REPO_FILTER    — only process this repo name (blank = all)
#   DRY_RUN        — true = report only, no deletions (default: false)
#   FORCE_DELETE   — true = also delete unmerged branches (default: false)
#   KEEP_PATTERNS  — space-separated glob patterns to always keep
#                    (default: "lts gh-pages main master")
#                    Note: upstream-commits/* are kept separately if they have an open PR

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${ORGS:?ORGS is required}"

GH_API="https://api.github.com"
DRY_RUN="${DRY_RUN:-false}"
FORCE_DELETE="${FORCE_DELETE:-false}"
REPO_FILTER="${REPO_FILTER:-}"
KEEP_PATTERNS="${KEEP_PATTERNS:-lts gh-pages main master}"


# ── Budget guard ─────────────────────────────────────────────────────────────
source "$(dirname "${BASH_SOURCE[0]}")/includes/budget.sh"
source "$(dirname "${BASH_SOURCE[0]}")/includes/gh-api.sh"
budget_init

info()  { echo "[cleanup-branches] $*" >&2; }
warn()  { echo "[cleanup-branches] ⚠️  $*" >&2; }
ok()    { echo "[cleanup-branches] ✅ $*"; }

deleted_total=0
skipped_total=0
repos_processed=0

gh_delete() {
  local url="$1"
  local attempt=0
  while true; do
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      "$url")
    if [[ "$http_code" == "204" || "$http_code" == "200" ]]; then
      return 0
    elif [[ "$http_code" == "403" || "$http_code" == "429" ]]; then
      (( attempt++ )) || true
      if (( attempt >= 3 )); then return 1; fi
      sleep 30
    else
      return 1
    fi
  done
}

# Cache: _REPO_DEFAULT_BRANCH["org/repo"] = branch name
# Cache: _REPO_BRANCHES["org/repo"] = space-separated branch names
declare -A _REPO_DEFAULT_BRANCH=()
declare -A _REPO_BRANCHES=()

# list_org_repos_graphql <org>
# Returns repo names via GraphQL (1 call). Falls back to paginated REST.
list_org_repos_graphql() {
  local org="$1" entity="organization"
  local result
  result=$(curl -sf \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Content-Type: application/json" \
    "${GH_API}/graphql" \
    -d "{\"query\":\"{ ${entity}(login: \\\"${org}\\\") { repositories(first: 100, orderBy: {field: NAME, direction: ASC}) { nodes { name defaultBranchRef { name } refs(refPrefix: \\\"refs/heads/\\\", first: 100) { nodes { name } } } pageInfo { hasNextPage endCursor } } } }\"}" \
    2>/dev/null || echo "{}")

  local count
  count=$(echo "$result" | python3 -c "
import json,sys
d=json.load(sys.stdin)
nodes=d.get('data',{}).get('${entity}',{}).get('repositories',{}).get('nodes',[])
print(len(nodes))
" 2>/dev/null || echo 0)

  if [[ "$count" -gt 0 ]]; then
    while IFS='|' read -r name default_branch branches; do
      [[ -z "$name" ]] && continue
      _REPO_DEFAULT_BRANCH["${org}/${name}"]="$default_branch"
      _REPO_BRANCHES["${org}/${name}"]="$branches"
      echo "$name"
    done < <(echo "$result" | python3 -c "
import json, sys
entity = '${entity}'
d = json.load(sys.stdin)
nodes = d.get('data',{}).get(entity,{}).get('repositories',{}).get('nodes',[])
for n in nodes:
    name = n.get('name','')
    ref  = n.get('defaultBranchRef') or {}
    default_branch = ref.get('name','main')
    branch_nodes = n.get('refs',{}).get('nodes',[])
    branches = ' '.join(b['name'] for b in branch_nodes)
    print(f'{name}|{default_branch}|{branches}')
" 2>/dev/null)
    return 0
  fi
  return 1
}

# Returns 0 if branch matches any keep pattern
should_keep() {
  local branch="$1"
  for pattern in $KEEP_PATTERNS; do
  # shellcheck disable=SC2254
   
    case "$branch" in
      $pattern) return 0 ;;
    esac
  done
  return 1
}

process_repo() {
  local org="$1" repo="$2"
  info "  ${org}/${repo}"

  # Use GraphQL-prefetched cache when available; fall back to REST
  local default_branch="${_REPO_DEFAULT_BRANCH["${org}/${repo}"]:-}"
  local all_branches="${_REPO_BRANCHES["${org}/${repo}"]:-}"

  if [[ -z "$default_branch" ]]; then
    local repo_info
    repo_info=$(gh_get "${GH_API}/repos/${org}/${repo}") || {
      warn "  Could not fetch repo info for ${org}/${repo} — skipping"
      return
    }
    default_branch=$(echo "$repo_info" | jq -r '.default_branch')
  fi

  if [[ -z "$all_branches" ]]; then
    local page=1
    while true; do
      local page_data page_branches
      page_data=$(gh_get "${GH_API}/repos/${org}/${repo}/branches?per_page=100&page=${page}") || break
      page_branches=$(echo "$page_data" | jq -r '.[].name' 2>/dev/null) || break
      [[ -z "$page_branches" ]] && break
      all_branches="${all_branches} ${page_branches}"
      local count
      count=$(echo "$page_branches" | wc -l)
      [[ "$count" -lt 100 ]] && break
      (( page++ ))
    done
  fi

  local branch_count
  branch_count=$(echo "$all_branches" | tr ' ' '\n' | grep -c '^.' || true)

  if [[ "$branch_count" -le 1 ]]; then
    info "    Only default branch — nothing to clean"
    return
  fi

  local deleted=0 skipped=0

  for branch in $all_branches; do
    [[ -z "$branch" ]] && continue

    # Always keep default branch
    if [[ "$branch" == "$default_branch" ]]; then
      continue
    fi

    # Keep branches matching keep patterns
    if should_keep "$branch"; then
      info "    Keeping (protected pattern): ${branch}"
      (( skipped++ )) || true
      continue
    fi

    # upstream-commits/* branches: keep only if they have an open PR,
    # regardless of merge status (these accumulate daily and are never
    # merged directly — they exist only to back a PR).
    case "$branch" in
      upstream-commits/*)
        local open_prs
        open_prs=$(gh_get "${GH_API}/repos/${org}/${repo}/pulls?state=open&head=${org}:${branch}&per_page=1" \
          2>/dev/null | jq -r 'length' 2>/dev/null || echo 0)
        if [[ "$open_prs" -gt 0 ]]; then
          info "    Keeping (open PR): ${branch}"
          (( skipped++ )) || true
          continue
        fi
        if [[ "$DRY_RUN" == "true" ]]; then
          info "    [dry-run] Would delete (no open PR): ${branch}"
        else
          if gh_delete "${GH_API}/repos/${org}/${repo}/git/refs/heads/${branch}"; then
            info "    Deleted (no open PR): ${branch}"
            (( deleted++ )) || true
          else
            warn "    Failed to delete: ${branch}"
            (( skipped++ )) || true
          fi
        fi
        continue
        ;;
    esac

    # Check if merged into default branch
    local compare
    compare=$(gh_get "${GH_API}/repos/${org}/${repo}/compare/${default_branch}...${branch}" 2>/dev/null) || {
      warn "    Could not compare ${branch} — skipping"
      (( skipped++ )) || true
      continue
    }

    local ahead_by status
    ahead_by=$(echo "$compare" | jq -r '.ahead_by // 0')
    status=$(echo "$compare" | jq -r '.status // "unknown"')

    if [[ "$ahead_by" -eq 0 ]] || [[ "$status" == "behind" ]] || [[ "$status" == "identical" ]]; then
      # Fully merged — safe to delete
      if [[ "$DRY_RUN" == "true" ]]; then
        info "    [dry-run] Would delete (merged): ${branch}"
        (( deleted++ )) || true
      else
        gh_delete "${GH_API}/repos/${org}/${repo}/git/refs/heads/${branch}" 2>/dev/null || true
        ok "    Deleted (merged): ${branch}"
        (( deleted++ )) || true
      fi
    elif [[ "$FORCE_DELETE" == "true" ]]; then
      # Unmerged but force delete requested
      if [[ "$DRY_RUN" == "true" ]]; then
        info "    [dry-run] Would delete (unmerged, ahead=${ahead_by}): ${branch}"
        (( deleted++ )) || true
      else
        gh_delete "${GH_API}/repos/${org}/${repo}/git/refs/heads/${branch}" 2>/dev/null || true
        warn "    Deleted (unmerged, ahead=${ahead_by}): ${branch}"
        (( deleted++ )) || true
      fi
    else
      info "    Keeping (unmerged, ahead=${ahead_by}): ${branch}"
      (( skipped++ )) || true
    fi
  done

  info "    → deleted=${deleted} skipped=${skipped}"
  (( deleted_total += deleted )) || true
  (( skipped_total += skipped )) || true
  (( repos_processed++ )) || true
}

# ── Main ──────────────────────────────────────────────────────────────────────

info "Starting branch cleanup"
info "  Orgs:         ${ORGS}"
info "  Dry run:      ${DRY_RUN}"
info "  Force delete: ${FORCE_DELETE}"
info "  Keep patterns: ${KEEP_PATTERNS}"
[[ -n "$REPO_FILTER" ]] && info "  Repo filter:  ${REPO_FILTER}"
echo ""

for org in $ORGS; do
    budget_check "${org}" || break
  info "=== ${org} ==="

  # Detect whether this is a user account or an org so we use the right endpoint.
  # /orgs/{name} returns 404 for user accounts; /users/{name} works for both but
  # only /orgs/{name}/repos returns private org repos, so we prefer org when available.
  # Detect account type to choose correct GraphQL entity field
  account_type=$(curl -sf \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Content-Type: application/json" \
    "${GH_API}/graphql" \
    -d "{\"query\":\"{ repositoryOwner(login: \\\"${org}\\\") { __typename } }\"}" \
    2>/dev/null | python3 -c "
import json,sys
print(json.load(sys.stdin).get('data',{}).get('repositoryOwner',{}).get('__typename','Organization'))
" 2>/dev/null || echo "Organization")

  if [[ "$account_type" == "User" ]]; then
    info "  User account detected — OSP-bound repos first, then remaining (budget permitting)"
    _CLEANUP_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _OSP_CFG="${OSP_REPOS_CONFIG:-${_CLEANUP_SCRIPT_DIR}/../config/gitlab-subgroups.yml}"
    # Fetch via GraphQL user query, fall back to REST
    _all_user_repos=""
    _gql_user=$(curl -sf \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "Content-Type: application/json" \
      "${GH_API}/graphql" \
      -d "{\"query\":\"{ user(login: \\\"${org}\\\") { repositories(first: 100, orderBy: {field: NAME, direction: ASC}) { nodes { name defaultBranchRef { name } refs(refPrefix: \\\"refs/heads/\\\", first: 100) { nodes { name } } } } } }\"}" \
      2>/dev/null || echo "{}")
    while IFS='|' read -r name default_branch branches; do
      [[ -z "$name" ]] && continue
      _REPO_DEFAULT_BRANCH["${org}/${name}"]="$default_branch"
      _REPO_BRANCHES["${org}/${name}"]="$branches"
      _all_user_repos="${_all_user_repos} ${name}"
    done < <(echo "$_gql_user" | python3 -c "
import json, sys
d = json.load(sys.stdin)
nodes = d.get('data',{}).get('user',{}).get('repositories',{}).get('nodes',[])
for n in nodes:
    name = n.get('name','')
    ref  = n.get('defaultBranchRef') or {}
    default_branch = ref.get('name','main')
    branches = ' '.join(b['name'] for b in n.get('refs',{}).get('nodes',[]))
    print(f'{name}|{default_branch}|{branches}')
" 2>/dev/null)
    if [[ -z "$_all_user_repos" ]]; then
      # Fallback to REST
      _cu_page=1
      while true; do
        _batch=$(gh_get "${GH_API}/users/${org}/repos?per_page=100&page=${_cu_page}&type=all") || break
        _count=$(echo "$_batch" | jq 'if type=="array" then length else 0 end' 2>/dev/null || echo 0)
        [[ "$_count" -eq 0 ]] && break
        _all_user_repos="${_all_user_repos} $(echo "$_batch" | jq -r '.[].name' | tr '\n' ' ')"
        [[ "$_count" -lt 100 ]] && break
        (( _cu_page++ )) || true
      done
    fi
    local_repos=$(osp_priority_repos "$_OSP_CFG" "$_all_user_repos")
  else
    # Org account — fetch via GraphQL with default branch + branches prefetched
    local_repos=""
    mapfile -t _gql_repos < <(list_org_repos_graphql "$org")
    if [[ ${#_gql_repos[@]} -gt 0 ]]; then
      local_repos="${_gql_repos[*]}"
    else
      # Fallback: paginated REST (no branch prefetch)
      local page=1
      while true; do
        local page_data page_repos
        page_data=$(gh_get "${GH_API}/orgs/${org}/repos?per_page=100&page=${page}&type=all") || {
          warn "Repo list failed for ${org} — skipping"
          break
        }
        page_repos=$(echo "$page_data" | jq -r '.[].name' 2>/dev/null) || break
        [[ -z "$page_repos" ]] && break
        local_repos="${local_repos} ${page_repos}"
        local count
        count=$(echo "$page_repos" | wc -l)
        [[ "$count" -lt 100 ]] && break
        (( page++ ))
      done
    fi
  fi

  while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    if [[ "$repo" == "---secondary---" ]]; then
      info "  [secondary pass — remaining budget only]"
      continue
    fi
    budget_check "$repo" || break
    if [[ -n "$REPO_FILTER" && "$repo" != "$REPO_FILTER" ]]; then
      continue
    fi
    process_repo "$org" "$repo"
  done <<< "$local_repos"
done

echo ""
info "========================================"
info " Branch cleanup complete"
info " Repos processed : ${repos_processed}"
info " Branches deleted: ${deleted_total}"
info " Branches kept   : ${skipped_total}"
[[ "$DRY_RUN" == "true" ]] && info " (dry run — no changes made)"
budget_report
info "========================================"
