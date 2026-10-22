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
MIN_FREE_DISK_MB="${MIN_FREE_DISK_MB:-512}"
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

_disk_free_mb() {
  local path="${1:-.}" available_kb
  available_kb=$(df -Pk "$path" 2>/dev/null | awk 'NR==2 {print $4}') || return 1
  [[ "$available_kb" =~ ^[0-9]+$ ]] || return 1
  printf "%s" "$((available_kb / 1024))"
}

_report_disk_free() {
  local path="$1" free_mb
  if free_mb=$(_disk_free_mb "$path"); then
    info "Disk space: ${free_mb} MiB available at ${path}"
  else
    warn "Disk space telemetry unavailable for ${path}"
  fi
}

_has_min_disk_space() {
  local path="$1" free_mb
  [[ "$MIN_FREE_DISK_MB" =~ ^[0-9]+$ ]] || {
    warn "MIN_FREE_DISK_MB must be a non-negative integer"
    return 2
  }
  free_mb=$(_disk_free_mb "$path") || {
    warn "Cannot determine free disk space at ${path}; refusing to start clone"
    return 4
  }
  if (( free_mb < MIN_FREE_DISK_MB )); then
    warn "Low disk space: ${free_mb} MiB available, ${MIN_FREE_DISK_MB} MiB required"
    return 3
  fi
  return 0
}

[[ "$DRY_RUN" == "true" ]] && info "Dry run — no pushes will occur."
[[ "$FORCE"   == "true" ]] && info "Force mode — all repos will be re-pushed."
[[ -n "$REPO_FILTER"    ]] && info "Repo filter: '${REPO_FILTER}'"
info "Direction: ${DIRECTION} | ${SOURCE_PLATFORM}/${SOURCE_ORG} ↔ ${DEST_PLATFORM}/${DEST_ORG}"

# ── git push with retry ───────────────────────────────────────────────────────
_git_push_retry() {
  local remote="$1"; shift
  local refspecs=("$@")
  local max_retries=3 attempt=0 output rc
  while true; do
    if output=$(git push "$remote" "${refspecs[@]}" 2>&1); then
      printf '%s\n' "$output" \
        | sed "s/${SOURCE_TOKEN}/***TOKEN***/g" \
        | sed "s/${DEST_TOKEN}/***TOKEN***/g"
      return 0
    else
      rc=$?
      printf '%s\n' "$output" \
        | sed "s/${SOURCE_TOKEN}/***TOKEN***/g" \
        | sed "s/${DEST_TOKEN}/***TOKEN***/g"
    fi

    # Tag-exists rejections are deterministic: retrying the same refspecs
    # cannot fix them. Tags are never force-updated by this helper.
    if printf '%s\n' "$output" | grep -Eiq 'tag .*already exists|already exists.*tag|would clobber existing tag'; then
      warn "Destination tag conflict — not retrying; existing tags are preserved"
      return 2
    fi

    (( attempt++ )) || true
    (( attempt > max_retries )) && { warn "Push failed after ${max_retries} attempts (exit ${rc})"; return 1; }
    local wait=$(( attempt * 15 ))
    warn "Push attempt ${attempt}/${max_retries} failed — retrying in ${wait}s"
    sleep "$wait"
  done
}

# ── destination tag preflight ────────────────────────────────────────────────
# Refuse the whole repo push if a destination tag name already points elsewhere.
# This avoids a multi-ref push partially updating branches before a tag rejection.
_preflight_destination_tags() {
  local remote="$1"; shift
  local tags=("$@") remote_tags tag local_oid remote_oid ref
  ((${#tags[@]} == 0)) && return 0

  if ! remote_tags=$(git ls-remote --tags "$remote" 2>&1); then
    warn "Cannot inspect destination tags; refusing to push refs"
    return 1
  fi

  for tag in "${tags[@]}"; do
    [[ -z "$tag" ]] && continue
    ref="refs/tags/$tag"
    local_oid=$(git rev-parse "$ref" 2>/dev/null) || {
      warn "Cannot resolve local tag $tag; refusing to push refs"
      return 1
    }
    remote_oid=$(printf '%s\n' "$remote_tags" | awk -v ref="$ref" '$2 == ref { print $1; exit }')
    if [[ -n "$remote_oid" && "$remote_oid" != "$local_oid" ]]; then
      warn "Destination tag conflict for $tag — not pushing any refs; existing tags are preserved"
      return 2
    fi
  done
  return 0
}

# ── _sync_repo FROM_PLATFORM FROM_ORG FROM_TOKEN FROM_HOST … ────────────
# Bare-clones REPO from FROM and pushes all branches+tags to TO.
# Creates the dest repo if CREATE_MISSING=true and it doesn't exist.
_sync_repo() {
  local from_platform="$1" from_org="$2" from_token="$3" from_host="$4"
  local to_platform="$5" to_org="$6" to_token="$7" to_host="$8" repo="$9"
  local create_missing="${10:-true}"

  local tmpdir
  tmpdir=$(mktemp -d)
  # Expand the path when installing the trap. RETURN can run after this
  # function's local scope has ended, where "$tmpdir" would be unbound under
  # nounset and turn an otherwise completed sync into a failure.
  trap "rm -rf -- '$tmpdir'" RETURN

  # Refuse to start a clone when the temporary filesystem is below the
  # configured threshold. Return 3 so the caller marks the leg incomplete.
  local disk_rc=0
  _has_min_disk_space "$tmpdir" || disk_rc=$?
  if [[ "$disk_rc" -eq 2 ]]; then
    warn "Invalid MIN_FREE_DISK_MB configuration; refusing to sync"
    return 1
  elif [[ "$disk_rc" -eq 3 ]]; then
    return 3
  elif [[ "$disk_rc" -eq 4 ]]; then
    return 4
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

  _report_disk_free "$tmpdir"
  info "  Cloning ${from_platform}/${from_org}/${repo} ..."
  if ! git clone --bare --quiet "$from_url" "$tmpdir/repo.git" 2>/dev/null; then
    warn "  Clone failed for ${from_org}/${repo} — skipping"
    return 1
  fi

  _report_disk_free "$tmpdir"
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

  # Preflight before both dry-run reporting and live pushes. Otherwise a dry run
  # can claim conflicting tags would be pushed without inspecting the destination.
  _preflight_destination_tags dest "${tags[@]}"
  local preflight_rc=$?
  if [[ "$preflight_rc" -ne 0 ]]; then
    popd > /dev/null
    return "$preflight_rc"
  fi

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

# ── _run_leg FROM_PLATFORM FROM_ORG FROM_TOKEN FROM_HOST … CREATE_MISSING ───
_run_leg() {
  local from_platform="$1" from_org="$2" from_token="$3" from_host="$4"
  local to_platform="$5" to_org="$6" to_token="$7" to_host="$8" create_missing="$9"
  local synced=0 failed=0 skipped=0 conflicts=0 incomplete=false stop_reason=none

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
    budget_check 5 || {
      warn "Budget exhausted — stopping early; remaining repositories were not processed"
      incomplete=true
      stop_reason=budget_exhausted
      break
    }

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
      local sync_rc=$?
      if [[ "$sync_rc" -eq 2 ]]; then
        warn "  ${repo}: destination tag conflict; recorded separately from general failures"
        (( conflicts++ )) || true
      elif [[ "$sync_rc" -eq 3 || "$sync_rc" -eq 4 ]]; then
        warn "  ${repo}: stopping sync before clone because disk space is insufficient or unknown"
        incomplete=true
        if [[ "$sync_rc" -eq 3 ]]; then stop_reason=low_disk_space; else stop_reason=disk_space_unknown; fi
        break
      else
        (( failed++ )) || true
      fi
    fi
  done

  info "Leg done. synced=${synced} failed=${failed} skipped=${skipped} tag_conflicts=${conflicts} complete=$([[ "$incomplete" == "false" ]] && echo true || echo false)"
  if [[ "$incomplete" == "true" ]]; then
    warn "Run incomplete: reason=${stop_reason}"
    return 1
  fi
  [[ "$failed" -gt 0 || "$conflicts" -gt 0 ]] && return 1
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
    _run_leg "$DEST_PLATFORM" "$DEST_ORG" "$DEST_TOKEN" "${DEST_HOST:-}" \
      "$SOURCE_PLATFORM" "$SOURCE_ORG" "$SOURCE_TOKEN" "${SOURCE_HOST:-}" "false" || overall_rc=1
    ;;
  *)
    warn "Unknown DIRECTION '${DIRECTION}'. Use: push | pull | both"
    exit 1
    ;;
esac

exit $overall_rc
