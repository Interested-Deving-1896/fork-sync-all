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
MIN_FREE_DISK_MB="${MIN_FREE_DISK_MB:-1024}"
DISK_GUARD_TRIPPED=false
if [[ ! "$MIN_FREE_DISK_MB" =~ ^[0-9]+$ ]]; then
  echo "[git-platform-sync][error] MIN_FREE_DISK_MB must be a non-negative integer" >&2
  exit 2
fi
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

_available_disk_mb() {
  df -Pm "$1" 2>/dev/null | awk 'NR == 2 { print $4; exit }'
}

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

# Tag pushes are deliberately single-attempt: a tag may appear after the
# ls-remote preflight, and retrying a deterministic name conflict cannot help.
# Branch pushes retain the transient-failure retry policy above.
_git_push_once() {
  local remote="$1"; shift
  local refspecs=("$@")
  if git push "$remote" "${refspecs[@]}" 2>&1 \
      | sed "s/${SOURCE_TOKEN}/***TOKEN***/g" \
      | sed "s/${DEST_TOKEN}/***TOKEN***/g"; then
    return 0
  fi
  warn "Tag push failed; not retrying (destination may have changed after preflight)"
  return 1
}

# ── _sync_repo FROM_PLATFORM FROM_ORG FROM_TOKEN FROM_HOST … ────────────
# Bare-clones REPO from FROM and pushes all branches+tags to TO.
# Creates the dest repo if CREATE_MISSING=true and it doesn't exist.
_sync_repo() {
  local from_platform="$1" from_org="$2" from_token="$3" from_host="$4"
  local to_platform="$5" to_org="$6" to_token="$7" to_host="$8" repo="$9"
  local create_missing="${10:-true}"

  local tmpdir
  if ! tmpdir=$(mktemp -d); then
    warn "  Could not create temporary workspace for ${repo}; stopping this sync leg safely"
    DISK_GUARD_TRIPPED=true
    return 1
  fi

  local free_mb
  free_mb=$(_available_disk_mb "$tmpdir")
  if [[ ! "$free_mb" =~ ^[0-9]+$ ]]; then
    warn "  Could not determine free disk space before cloning ${repo}; stopping this sync leg safely"
    DISK_GUARD_TRIPPED=true
    rm -rf -- "$tmpdir"
    return 1
  fi
  info "  Available disk before clone: ${free_mb} MB (minimum ${MIN_FREE_DISK_MB} MB)"
  if (( free_mb < MIN_FREE_DISK_MB )); then
    warn "  Disk-space guard tripped before cloning ${repo}: ${free_mb} MB available, ${MIN_FREE_DISK_MB} MB required; stopping this sync leg"
    DISK_GUARD_TRIPPED=true
    rm -rf -- "$tmpdir"
    return 1
  fi

  # Initialise adapters for this direction
  PLATFORM="$from_platform" PLATFORM_TOKEN="$from_token" \
    PLATFORM_HOST="$from_host" pa_init "$from_platform" "$from_host" 2>/dev/null
  local from_url
  from_url=$(pa_clone_url "$from_org" "$repo")

  PLATFORM="$to_platform" PLATFORM_TOKEN="$to_token" \
    PLATFORM_HOST="$to_host" pa_init "$to_platform" "$to_host" 2>/dev/null
  local to_url
  to_url=$(pa_push_url "$to_org" "$repo")

  # Create dest repo if needed
  if [[ "$create_missing" == "true" ]]; then
    pa_create_repo "$to_org" "$repo" "Mirror of ${from_platform}/${from_org}/${repo}" 2>/dev/null || true
  fi

  info "  Cloning ${from_platform}/${from_org}/${repo} ..."
  if ! git clone --bare --quiet "$from_url" "$tmpdir/repo.git" 2>/dev/null; then
    warn "  Clone failed for ${from_org}/${repo} — skipping"
    rm -rf -- "$tmpdir"
    return 1
  fi

  if ! pushd "$tmpdir/repo.git" > /dev/null; then
    warn "  Could not enter bare clone workspace for ${repo}"
    rm -rf -- "$tmpdir"
    return 1
  fi

  # Collect all branches and tags
  local branches tags
  # A --bare clone stores branches under refs/heads; it has no origin/* remote-tracking refs.
  mapfile -t branches < <(git for-each-ref --format='%(refname:strip=2)' refs/heads/ 2>/dev/null || true)
  mapfile -t tags     < <(git tag 2>/dev/null || true)

  if [[ ${#branches[@]} -eq 0 && ${#tags[@]} -eq 0 ]]; then
    info "  No refs to push for ${repo} — skipping"
    if ! popd > /dev/null; then
      warn "  Could not restore directory stack for Interested-Deving-1896/fork-sync-all"
      rm -rf -- "$tmpdir"
      return 1
    fi
    rm -rf -- "$tmpdir"
    return 0
  fi

  git remote add dest "$to_url" 2>/dev/null || git remote set-url dest "$to_url"

  # Build branch refspecs separately so a pre-existing tag cannot block branch sync.
  local branch_refspecs=()
  for branch in "${branches[@]}"; do
    branch="${branch// /}"
    [[ -z "$branch" ]] && continue
    if [[ "$FORCE" == "true" ]]; then
      branch_refspecs+=("+refs/heads/${branch}:refs/heads/${branch}")
    else
      branch_refspecs+=("refs/heads/${branch}:refs/heads/${branch}")
    fi
  done

  # Never overwrite destination tags implicitly. Inspect the destination first;
  # if inspection fails, fail closed for tags while still allowing branch sync.
  local existing_tag_refs=() existing_tags=() safe_tag_refspecs=() tag
  if ! git ls-remote --refs dest 'refs/tags/*' > "$tmpdir/dest-tags.txt"; then
    warn "  Could not inspect destination tags for ${repo}; refusing to push tags"
  else
    mapfile -t existing_tag_refs < "$tmpdir/dest-tags.txt"
    for tag_ref in "${existing_tag_refs[@]}"; do
      [[ -z "$tag_ref" ]] && continue
      existing_tags+=("${tag_ref#*refs/tags/}")
    done
    for tag in "${tags[@]}"; do
      tag="${tag// /}"
      [[ -z "$tag" ]] && continue
      local found=false existing_tag
      for existing_tag in "${existing_tags[@]}"; do
        if [[ "$tag" == "$existing_tag" ]]; then
          found=true
          break
        fi
      done
      if [[ "$found" == "true" ]]; then
        info "  Tag ${tag} already exists on destination; preserving destination tag"
      else
        safe_tag_refspecs+=("refs/tags/${tag}:refs/tags/${tag}")
      fi
    done
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    dry "would push ${#branch_refspecs[@]} branch ref(s) and ${#safe_tag_refspecs[@]} new tag(s) to ${to_platform}/${to_org}/${repo}"
    if ! popd > /dev/null; then
      warn "  Could not restore directory stack for Interested-Deving-1896/fork-sync-all"
      rm -rf -- "$tmpdir"
      return 1
    fi
    rm -rf -- "$tmpdir"
    return 0
  fi

  local rc=0
  if [[ ${#branch_refspecs[@]} -gt 0 ]]; then
    info "  Pushing ${#branch_refspecs[@]} branch ref(s) → ${to_platform}/${to_org}/${repo}"
    _git_push_retry dest "${branch_refspecs[@]}" || rc=1
  fi
  if [[ ${#safe_tag_refspecs[@]} -gt 0 ]]; then
    info "  Pushing ${#safe_tag_refspecs[@]} new tag(s) → ${to_platform}/${to_org}/${repo}"
    _git_push_once dest "${safe_tag_refspecs[@]}" || rc=1
  fi
  if ! popd > /dev/null; then
    warn "  Could not restore directory stack for Interested-Deving-1896/fork-sync-all"
    rm -rf -- "$tmpdir"
    return 1
  fi
  rm -rf -- "$tmpdir"
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

# ── _run_leg FROM_PLATFORM FROM_ORG FROM_TOKEN FROM_HOST … CREATE_MISSING ───
_run_leg() {
  local from_platform="$1" from_org="$2" from_token="$3" from_host="$4"
  local to_platform="$5" to_org="$6" to_token="$7" to_host="$8" create_missing="$9"
  local synced=0 failed=0 skipped=0

  info "Leg: ${from_platform}/${from_org} → ${to_platform}/${to_org}"

  # Initialise source adapter to list repos
  PLATFORM="$from_platform" PLATFORM_TOKEN="$from_token" \
    PLATFORM_HOST="$from_host" pa_init "$from_platform" "$from_host"

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
      PLATFORM="$to_platform" PLATFORM_TOKEN="$to_token" \
        PLATFORM_HOST="$to_host" pa_init "$to_platform" "$to_host"
      if ! pa_repo_exists "$to_org" "$repo" 2>/dev/null; then
        info "  ${repo}: not on ${to_platform}/${to_org} — skipping (pull leg never creates)"
        (( skipped++ )) || true
        continue
      fi
    fi

    info "${from_platform}/${from_org}/${repo}  →  ${to_platform}/${to_org}/${repo}"
    if _sync_repo "$from_platform" "$from_org" "$from_token" "$from_host" \
        "$to_platform" "$to_org" "$to_token" "$to_host" "$repo" "$create_missing"; then
      (( synced++ )) || true
    else
      (( failed++ )) || true
    fi
    if [[ "$DISK_GUARD_TRIPPED" == "true" ]]; then
      warn "Disk-space guard stopped the leg early; synced=${synced} failed=${failed} skipped=${skipped} (inventory may be incomplete)"
      break
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
    _run_leg "$SOURCE_PLATFORM" "$SOURCE_ORG" "$SOURCE_TOKEN" "${SOURCE_HOST:-}" \
      "$DEST_PLATFORM" "$DEST_ORG" "$DEST_TOKEN" "${DEST_HOST:-}" "true" || overall_rc=1
    ;;
  pull)
    _run_leg "$DEST_PLATFORM" "$DEST_ORG" "$DEST_TOKEN" "${DEST_HOST:-}" \
      "$SOURCE_PLATFORM" "$SOURCE_ORG" "$SOURCE_TOKEN" "${SOURCE_HOST:-}" "false" || overall_rc=1
    ;;
  both)
    _run_leg "$SOURCE_PLATFORM" "$SOURCE_ORG" "$SOURCE_TOKEN" "${SOURCE_HOST:-}" \
      "$DEST_PLATFORM" "$DEST_ORG" "$DEST_TOKEN" "${DEST_HOST:-}" "true" || overall_rc=1
    if [[ "$DISK_GUARD_TRIPPED" == "true" ]]; then
      warn "Skipping second sync leg because the disk-space guard stopped the first leg"
      overall_rc=1
    else
      _run_leg "$DEST_PLATFORM" "$DEST_ORG" "$DEST_TOKEN" "${DEST_HOST:-}" \
        "$SOURCE_PLATFORM" "$SOURCE_ORG" "$SOURCE_TOKEN" "${SOURCE_HOST:-}" "false" || overall_rc=1
    fi
    ;;
  *)
    warn "Unknown DIRECTION '${DIRECTION}'. Use: push | pull | both"
    exit 1
    ;;
esac

exit $overall_rc
