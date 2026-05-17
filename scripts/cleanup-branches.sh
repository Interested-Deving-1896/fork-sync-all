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

info()  { echo "[cleanup-branches] $*"; }
warn()  { echo "[cleanup-branches] ⚠️  $*"; }
ok()    { echo "[cleanup-branches] ✅ $*"; }

deleted_total=0
skipped_total=0
repos_processed=0

gh_get() {
  local url="$1"
  curl -sf \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "$url"
}

gh_delete() {
  local url="$1"
  curl -sf -X DELETE \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "$url"
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

  # Get default branch
  local repo_info default_branch
  repo_info=$(gh_get "${GH_API}/repos/${org}/${repo}") || {
    warn "  Could not fetch repo info for ${org}/${repo} — skipping"
    return
  }
  default_branch=$(echo "$repo_info" | jq -r '.default_branch')

  # Get all branches
  local branches page=1 all_branches=""
  while true; do
    local page_data
    page_data=$(gh_get "${GH_API}/repos/${org}/${repo}/branches?per_page=100&page=${page}") || break
    local page_branches
    page_branches=$(echo "$page_data" | jq -r '.[].name' 2>/dev/null) || break
    [[ -z "$page_branches" ]] && break
    all_branches="${all_branches} ${page_branches}"
    local count
    count=$(echo "$page_branches" | wc -l)
    [[ "$count" -lt 100 ]] && break
    (( page++ ))
  done

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
  info "=== ${org} ==="

  # Detect whether this is a user account or an org so we use the right endpoint.
  # /orgs/{name} returns 404 for user accounts; /users/{name} works for both but
  # only /orgs/{name}/repos returns private org repos, so we prefer org when available.
  account_type=$(gh_get "${GH_API}/users/${org}" | jq -r '.type // "Organization"' 2>/dev/null)
  if [[ "$account_type" == "User" ]]; then
    repo_endpoint="${GH_API}/users/${org}/repos"
    # User accounts (e.g. Interested-Deving-1896) can have thousands of repos.
    # Scope cleanup to only OSP-mirrored repos to avoid timeout.
    info "  User account detected — scoping to OSP-mirrored repos only"
    osp_repos=$(gh_get "${GH_API}/orgs/OpenOS-Project-OSP/repos?per_page=100&type=all" \
      | jq -r '.[].name' 2>/dev/null)
    local_repos="$osp_repos"
  else
    repo_endpoint="${GH_API}/orgs/${org}/repos"
    # Fetch all repos — paginate fully
    local_repos="" page=1
    while true; do
      page_data=$(gh_get "${repo_endpoint}?per_page=100&page=${page}&type=all") || {
        warn "Repo list failed for ${org} — skipping"
        break
      }
      page_repos=$(echo "$page_data" | jq -r '.[].name' 2>/dev/null) || break
      [[ -z "$page_repos" ]] && break
      local_repos="${local_repos} ${page_repos}"
      count=$(echo "$page_repos" | wc -l)
      [[ "$count" -lt 100 ]] && break
    done
  fi

  for repo in $local_repos; do
    [[ -z "$repo" ]] && continue
    if [[ -n "$REPO_FILTER" && "$repo" != "$REPO_FILTER" ]]; then
      continue
    fi
    process_repo "$org" "$repo"
  done
done

echo ""
info "========================================"
info " Branch cleanup complete"
info " Repos processed : ${repos_processed}"
info " Branches deleted: ${deleted_total}"
info " Branches kept   : ${skipped_total}"
[[ "$DRY_RUN" == "true" ]] && info " (dry run — no changes made)"
info "========================================"
