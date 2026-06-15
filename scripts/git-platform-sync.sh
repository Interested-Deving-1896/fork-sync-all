#!/usr/bin/env bash
#
# scripts/git-platform-sync.sh — agnostic git platform sync
#
# Syncs repos between any two git hosting platforms (GitHub, GitLab, Gitea,
# Forgejo, Codeberg). Replaces the platform-specific sync-to-gitlab.sh and
# sync-from-gitlab.sh with a single configurable backend.
#
# ── How it works ──────────────────────────────────────────────────────────────
#
#   push  — bare-clone each repo from SOURCE_PLATFORM/SOURCE_ORG, push all
#           branches and tags to DEST_PLATFORM/DEST_ORG. Creates the dest
#           repo if it doesn't exist. Preserves dest-only branches (no prune).
#
#   pull  — bare-clone each repo from DEST_PLATFORM/DEST_ORG, push all
#           branches and tags back to SOURCE_PLATFORM/SOURCE_ORG. Only syncs
#           repos that already exist on the source (no new repos created).
#
#   both  — push leg first, then pull leg.
#
# ── Required env vars ─────────────────────────────────────────────────────────
#
#   SOURCE_PLATFORM   — github | gitlab | gitea | forgejo | codeberg
#   SOURCE_ORG        — org/group/namespace on the source platform
#   SOURCE_TOKEN      — auth token for the source platform
#   DEST_PLATFORM     — github | gitlab | gitea | forgejo | codeberg
#   DEST_ORG          — org/group/namespace on the destination platform
#   DEST_TOKEN        — auth token for the destination platform
#
# ── Optional env vars ─────────────────────────────────────────────────────────
#
#   DIRECTION         — push | pull | both (default: push)
#   REPO_FILTER       — only sync repos whose name contains this substring
#   DRY_RUN           — "true" = report without pushing (default: false)
#   FORCE             — "true" = force-push even if dest has diverged (default: false)
#   CREATE_MISSING    — "true" = create dest repo if absent (default: true for push,
#                       false for pull — pull never creates source repos)
#   SOURCE_HOST       — base URL override for source (e.g. https://gitlab.myco.com)
#   DEST_HOST         — base URL override for dest
#   BUDGET_MINUTES    — max runtime in minutes (default: 55)
#   SUBGROUP_FILTER   — GitLab only: limit to this subgroup path under DEST_ORG/SOURCE_ORG
#   EXCLUDED_REPOS    — space-separated repo names to never sync

set -uo pipefail

: "${SOURCE_PLATFORM:?SOURCE_PLATFORM is required}"
: "${SOURCE_ORG:?SOURCE_ORG is required}"
: "${SOURCE_TOKEN:?SOURCE_TOKEN is required}"
: "${DEST_PLATFORM:?DEST_PLATFORM is required}"
: "${DEST_ORG:?DEST_ORG is required}"
: "${DEST_TOKEN:?DEST_TOKEN is required}"

DIRECTION="${DIRECTION:-push}"
REPO_FILTER="${REPO_FILTER:-}"
DRY_RUN="${DRY_RUN:-false}"
FORCE="${FORCE:-false}"
BUDGET_MINUTES="${BUDGET_MINUTES:-55}"
SUBGROUP_FILTER="${SUBGROUP_FILTER:-}"
EXCLUDED_REPOS="${EXCLUDED_REPOS:-}"

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/includes/platform-adapter.sh
source "${_SCRIPT_DIR}/includes/platform-adapter.sh"
# shellcheck source=scripts/includes/budget.sh
source "${_SCRIPT_DIR}/includes/budget.sh"
budget_init

info() { echo "[git-platform-sync] $*" >&2; }
warn() { echo "[git-platform-sync][warn] $*" >&2; }
dry()  { echo "[git-platform-sync][dry-run] $*" >&2; }

[[ "$DRY_RUN" == "true" ]] && info "Dry run — no pushes will occur."
[[ "$FORCE"   == "true" ]] && info "Force mode — all repos will be re-pushed."
[[ -n "$REPO_FILTER"    ]] && info "Repo filter: '${REPO_FILTER}'"
info "Direction: ${DIRECTION} | ${SOURCE_PLATFORM}/${SOURCE_ORG} ↔ ${DEST_PLATFORM}/${DEST_ORG}"

# ── git push with retry ───────────────────────────────────────────────────────
_git_push_retry() {
  local remote="$1"; shift
  local refspecs=("$@")
  local max_retries=3 attempt=0
  while true; do
    if git push "$remote" "${refspecs[@]}" 2>&1 \
        | sed "s/${SOURCE_TOKEN}/***TOKEN***/g" \
        | sed "s/${DEST_TOKEN}/***TOKEN***/g"; then
      return 0
    fi
    (( attempt++ )) || true
    (( attempt > max_retries )) && { warn "Push failed after ${max_retries} attempts"; return 1; }
    local wait=$(( attempt * 15 ))
    warn "Push attempt ${attempt}/${max_retries} failed — retrying in ${wait}s"
    sleep "$wait"
  done
}

# ── _sync_repo FROM_PLATFORM FROM_ORG TO_PLATFORM TO_ORG REPO ────────────────
# Bare-clones REPO from FROM and pushes all branches+tags to TO.
# Creates the dest repo if CREATE_MISSING=true and it doesn't exist.
_sync_repo() {
  local from_platform="$1" from_org="$2" to_platform="$3" to_org="$4" repo="$5"
  local create_missing="${6:-true}"

  local tmpdir
  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' RETURN

  # Initialise adapters for this direction
  PLATFORM="$from_platform" PLATFORM_TOKEN="$SOURCE_TOKEN" \
    PLATFORM_HOST="${SOURCE_HOST:-}" pa_init "$from_platform" "${SOURCE_HOST:-}" 2>/dev/null
  local from_url
  from_url=$(pa_clone_url "$from_org" "$repo")

  PLATFORM="$to_platform" PLATFORM_TOKEN="$DEST_TOKEN" \
    PLATFORM_HOST="${DEST_HOST:-}" pa_init "$to_platform" "${DEST_HOST:-}" 2>/dev/null
  local to_url
  to_url=$(pa_push_url "$to_org" "$repo")

  # Create dest repo if needed
  if [[ "$create_missing" == "true" ]]; then
    pa_create_repo "$to_org" "$repo" "Mirror of ${from_platform}/${from_org}/${repo}" 2>/dev/null || true
  fi

  info "  Cloning ${from_platform}/${from_org}/${repo} ..."
  if ! git clone --bare --quiet "$from_url" "$tmpdir/repo.git" 2>/dev/null; then
    warn "  Clone failed for ${from_org}/${repo} — skipping"
    return 1
  fi

  pushd "$tmpdir/repo.git" > /dev/null

  # Collect all branches and tags
  local branches tags
  mapfile -t branches < <(git branch -r 2>/dev/null | sed 's|origin/||' | grep -v HEAD || true)
  mapfile -t tags     < <(git tag 2>/dev/null || true)

  if [[ ${#branches[@]} -eq 0 && ${#tags[@]} -eq 0 ]]; then
    info "  No refs to push for ${repo} — skipping"
    popd > /dev/null
    return 0
  fi

  git remote add dest "$to_url" 2>/dev/null || git remote set-url dest "$to_url"

  # Build refspecs — force-push branches, regular push tags
  local refspecs=()
  for branch in "${branches[@]}"; do
    branch="${branch// /}"
    [[ -z "$branch" ]] && continue
    if [[ "$FORCE" == "true" ]]; then
      refspecs+=("+refs/heads/${branch}:refs/heads/${branch}")
    else
      refspecs+=("refs/heads/${branch}:refs/heads/${branch}")
    fi
  done
  for tag in "${tags[@]}"; do
    tag="${tag// /}"
    [[ -z "$tag" ]] && continue
    refspecs+=("refs/tags/${tag}:refs/tags/${tag}")
  done

  if [[ "$DRY_RUN" == "true" ]]; then
    dry "would push ${#branches[@]} branch(es) + ${#tags[@]} tag(s) to ${to_platform}/${to_org}/${repo}"
    popd > /dev/null
    return 0
  fi

  info "  Pushing ${#branches[@]} branch(es) + ${#tags[@]} tag(s) → ${to_platform}/${to_org}/${repo}"
  _git_push_retry dest "${refspecs[@]}"
  local rc=$?
  popd > /dev/null
  return $rc
}

# ── _is_excluded REPO ─────────────────────────────────────────────────────────
_is_excluded() {
  local repo="$1"
  for ex in $EXCLUDED_REPOS; do
    [[ "$repo" == "$ex" ]] && return 0
  done
  return 1
}

# ── _run_leg FROM_PLATFORM FROM_ORG TO_PLATFORM TO_ORG CREATE_MISSING ────────
_run_leg() {
  local from_platform="$1" from_org="$2" to_platform="$3" to_org="$4" create_missing="$5"
  local synced=0 failed=0 skipped=0

  info "Leg: ${from_platform}/${from_org} → ${to_platform}/${to_org}"

  # Initialise source adapter to list repos
  PLATFORM="$from_platform" PLATFORM_TOKEN="$SOURCE_TOKEN" \
    PLATFORM_HOST="${SOURCE_HOST:-}" pa_init "$from_platform" "${SOURCE_HOST:-}"

  # Apply subgroup filter for GitLab sources
  local list_org="$from_org"
  if [[ -n "$SUBGROUP_FILTER" && "$from_platform" == "gitlab" ]]; then
    list_org="${from_org}/${SUBGROUP_FILTER}"
    info "Subgroup filter: ${list_org}"
  fi

  local repos
  mapfile -t repos < <(pa_list_repos "$list_org" 2>/dev/null)
  info "Found ${#repos[@]} repos in ${from_platform}/${list_org}"

  for repo in "${repos[@]}"; do
    [[ -z "$repo" ]] && continue
    budget_check 5 || { warn "Budget exhausted — stopping early"; break; }

    # Apply name filter
    if [[ -n "$REPO_FILTER" && "$repo" != *"$REPO_FILTER"* ]]; then
      continue
    fi

    # Skip excluded repos
    if _is_excluded "$repo"; then
      info "  ${repo}: excluded — skipping"
      (( skipped++ )) || true
      continue
    fi

    # For pull leg: only sync repos that already exist on source (no new repos)
    if [[ "$create_missing" == "false" ]]; then
      PLATFORM="$to_platform" PLATFORM_TOKEN="$DEST_TOKEN" \
        PLATFORM_HOST="${DEST_HOST:-}" pa_init "$to_platform" "${DEST_HOST:-}"
      if ! pa_repo_exists "$to_org" "$repo" 2>/dev/null; then
        info "  ${repo}: not on ${to_platform}/${to_org} — skipping (pull leg never creates)"
        (( skipped++ )) || true
        continue
      fi
    fi

    info "${from_platform}/${from_org}/${repo}  →  ${to_platform}/${to_org}/${repo}"
    if _sync_repo "$from_platform" "$from_org" "$to_platform" "$to_org" "$repo" "$create_missing"; then
      (( synced++ )) || true
    else
      (( failed++ )) || true
    fi
  done

  info "Leg done. synced=${synced} failed=${failed} skipped=${skipped}"
  [[ "$failed" -gt 0 ]] && return 1
  return 0
}

# ── Main ──────────────────────────────────────────────────────────────────────
overall_rc=0

case "$DIRECTION" in
  push)
    _run_leg "$SOURCE_PLATFORM" "$SOURCE_ORG" "$DEST_PLATFORM" "$DEST_ORG" "true" || overall_rc=1
    ;;
  pull)
    _run_leg "$DEST_PLATFORM" "$DEST_ORG" "$SOURCE_PLATFORM" "$SOURCE_ORG" "false" || overall_rc=1
    ;;
  both)
    _run_leg "$SOURCE_PLATFORM" "$SOURCE_ORG" "$DEST_PLATFORM" "$DEST_ORG" "true"  || overall_rc=1
    _run_leg "$DEST_PLATFORM"   "$DEST_ORG"   "$SOURCE_PLATFORM" "$SOURCE_ORG" "false" || overall_rc=1
    ;;
  *)
    warn "Unknown DIRECTION '${DIRECTION}'. Use: push | pull | both"
    exit 1
    ;;
esac

exit $overall_rc
