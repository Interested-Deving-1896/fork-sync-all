#!/usr/bin/env bash
#
# Mirrors GitLab openos-project repos into their GitHub Interested-Deving-1896
# counterparts, but only for repos that already exist on GitHub (name match).
#
# For each GitLab project found across all openos-project subgroups:
#   1. Check if a repo with the same name exists in GITHUB_OWNER
#   2. If yes, bare-clone from GitLab and push all branches + tags to GitHub
#   3. GitHub-only branches (org-ref commits, etc.) are preserved because we
#      push selectively (+refs/heads/* +refs/tags/*) without --mirror prune
#
# Required env vars:
#   GITLAB_TOKEN  — GitLab PAT with read_repository scope
#   GH_TOKEN      — GitHub PAT with repo + workflow scopes
#   GITHUB_OWNER  — GitHub org to push into (Interested-Deving-1896)

set -uo pipefail

: "${GITLAB_TOKEN:?GITLAB_TOKEN is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"

DRY_RUN="${DRY_RUN:-false}"
REPO_FILTER="${REPO_FILTER:-}"
: "${GITHUB_OWNER:=Interested-Deving-1896}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/branch-name-conv.sh
source "${SCRIPT_DIR}/branch-name-conv.sh"
# shellcheck source=scripts/includes/budget.sh
source "${SCRIPT_DIR}/includes/budget.sh"
# shellcheck source=scripts/includes/platform-adapter.sh
source "${SCRIPT_DIR}/includes/platform-adapter.sh"

GH_API="https://api.github.com"

# Initialise platform adapters — GitLab for reads, GitHub for existence checks.
PLATFORM=gitlab PLATFORM_TOKEN="$GITLAB_TOKEN" pa_init gitlab
# GitHub adapter initialised inline where needed (pa_init is idempotent per platform).

# ── Budget guard ─────────────────────────────────────────────────────────────
budget_init

declare -A SUBGROUP_NAME_TO_ID=(
  [penguins-eggs_deving]=130516402
  [immutable-filesystem_deving]=130516465
  [incus_deving]=130516536
  [linux-kernel_filesystem_deving]=130516188
  [ops]=130734009
)

# SUBGROUP_FILTER: if set, only scan the named subgroup (from workflow_dispatch input)
SUBGROUP_FILTER="${SUBGROUP_FILTER:-}"

if [[ -n "$SUBGROUP_FILTER" ]]; then
  if [[ -z "${SUBGROUP_NAME_TO_ID[$SUBGROUP_FILTER]+x}" ]]; then
    echo "ERROR: Unknown subgroup filter '${SUBGROUP_FILTER}'. Valid values: ${!SUBGROUP_NAME_TO_ID[*]}" >&2
    exit 1
  fi
  SUBGROUP_IDS=( "${SUBGROUP_NAME_TO_ID[$SUBGROUP_FILTER]}" )
else
  SUBGROUP_IDS=(
    130516402   # penguins-eggs_deving
    130516465   # immutable-filesystem_deving
    130516536   # incus_deving
    130516188   # linux-kernel_filesystem_deving
    130734009   # ops
  )
fi

# Repos to never push to GitHub (GitLab-native infra, no GitHub counterpart intended)
EXCLUDED_REPOS=(
  "ops"
  "ops-panel"
  "incus_deving"
  "penguins-eggs_deving"
  "immutable-filesystem_deving"
  "linux-kernel_filesystem_deving"
  "git-management_deving"
)

# Helpers must be defined before any call site (including the early log lines below)
info() { echo "[sync-from-gitlab] $*" >&2; }
warn() { echo "[warn] $*" >&2; }

[[ "$DRY_RUN" == "true" ]] && info "Dry run — no pushes will occur."
[[ -n "$REPO_FILTER"    ]] && info "Repo filter: '${REPO_FILTER}'"
[[ -n "$SUBGROUP_FILTER" ]] && info "Subgroup filter: ${SUBGROUP_FILTER} (id=${SUBGROUP_IDS[0]})"

# ── API helpers ───────────────────────────────────────────────────────────────
# Rate-limit retry is handled by pa_api_get (platform-adapter.sh).
# gl_api_get and gh_api_check are thin wrappers kept for call-site compatibility.

gl_api_get() {
  # GitLab GET — delegates to pa_api_get with GitLab adapter active.
  PLATFORM=gitlab PLATFORM_TOKEN="$GITLAB_TOKEN" pa_init gitlab 2>/dev/null
  pa_api_get "$@"
}

gh_api_check() {
  # Lightweight GitHub existence check — returns HTTP status code string.
  # Returns "200" if exists, "404" if not, other codes on error.
  local url="$1"
  PLATFORM=github PLATFORM_TOKEN="$GH_TOKEN" pa_init github 2>/dev/null
  local body
  body=$(pa_api_get "$url" 2>/dev/null)
  if [[ -n "$body" && "$body" != "null" ]]; then
    echo "200"
  else
    echo "404"
  fi
}

is_excluded() {
  local name="$1"
  for ex in "${EXCLUDED_REPOS[@]}"; do
    [[ "$name" == "$ex" ]] && return 0
  done
  return 1
}

# Returns all project paths (path, not name) in a subgroup
get_subgroup_projects() {
  local group_id="$1"
  local page=1
  local gl_api="${PA_API:-https://gitlab.com/api/v4}"
  while true; do
    local result count
    result=$(gl_api_get "${gl_api}/groups/${group_id}/projects?per_page=100&page=${page}&simple=true") || break
    count=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d))" 2>/dev/null || echo 0)
    [[ "$count" -eq 0 ]] && break
    # Output: "gl_project_id|repo_name|gl_path_with_namespace"
    echo "$result" | python3 -c "
import sys, json
for p in json.load(sys.stdin):
    print(f\"{p['id']}|{p['path']}|{p['path_with_namespace']}\")"
    (( page++ ))
  done
}

github_repo_exists() {
  local name="$1"
  local status
  status=$(gh_api_check "${GH_API}/repos/${GITHUB_OWNER}/${name}")
  [[ "$status" == "200" ]]
}

sync_repo() {
  local gl_path="$1" gh_name="$2"

  PLATFORM=gitlab PLATFORM_TOKEN="$GITLAB_TOKEN" pa_init gitlab 2>/dev/null
  local gl_url
  gl_url=$(pa_clone_url "$(dirname "$gl_path")" "$(basename "$gl_path")")
  PLATFORM=github PLATFORM_TOKEN="$GH_TOKEN" pa_init github 2>/dev/null
  # shellcheck disable=SC2034
  local gh_url
  gh_url=$(pa_push_url "$GITHUB_OWNER" "$gh_name")

  local work_dir
  work_dir=$(mktemp -d)

  info "  Cloning gitlab.com/${gl_path} ..."
  local clone_out
  clone_out=$(git clone --mirror "$gl_url" "$work_dir" 2>&1) || {
    # Distinguish access-denied (token lacks scope) from other errors.
    # Return 2 for access failures so the caller can skip rather than fail.
    if echo "$clone_out" | grep -qiE "403|401|not found|access denied|repository not found"; then
      warn "  Clone skipped (access denied) for ${gl_path} — check GITLAB_SYNC_TOKEN scope"
      rm -rf "$work_dir"
      return 2
    fi
    warn "  Clone failed for ${gl_path}: ${clone_out}"
    rm -rf "$work_dir"
    return 1
  }

  cd "$work_dir" || exit 1

  local push_ok=true

  # Push all branches back to GitHub, decoding any encoded names (e.g.
  # upstream-commits--S--Org--S--repo--S--YYYY-MM-DD → upstream-commits/Org/repo/YYYY-MM-DD)
  # that were encoded when originally pushed from GitHub to GitLab.
  push_branches_decoded "$gh_url" 2>&1 \
    | sed "s/${GH_TOKEN}/***TOKEN***/g" \
    | sed "s/${GITLAB_TOKEN}/***TOKEN***/g" \
    || push_ok=false

  # Push tags (non-fatal if some already exist)
  git push "$gh_url" '+refs/tags/*:refs/tags/*' 2>&1 \
    | sed "s/${GH_TOKEN}/***TOKEN***/g" \
    | sed "s/${GITLAB_TOKEN}/***TOKEN***/g" \
    || true

  cd /
  rm -rf "$work_dir"

  $push_ok
}

# ── main ─────────────────────────────────────────────────────────────────────

synced=0
failed=0
skipped=0

for group_id in "${SUBGROUP_IDS[@]}"; do
    budget_check "$group_id" || break
  info "Scanning subgroup ${group_id} ..."

  while IFS='|' read -r _gl_id gl_name gl_path; do
    [[ -z "$gl_name" ]] && continue

    if is_excluded "$gl_name"; then
      (( skipped++ )) || true
      continue
    fi

    # Apply repo name substring filter
    if [[ -n "$REPO_FILTER" && "$gl_name" != *"$REPO_FILTER"* ]]; then
      (( skipped++ )) || true
      continue
    fi

    # Only sync if a GitHub repo with the same name exists
    if ! github_repo_exists "$gl_name"; then
      (( skipped++ )) || true
      continue
    fi

    info "──────────────────────────────────────────"
    info "gitlab.com/${gl_path}  →  github.com/${GITHUB_OWNER}/${gl_name}"

    if [[ "$DRY_RUN" == "true" ]]; then
      info "  DRY  would sync ${gl_name}"
      (( synced++ )) || true
      continue
    fi

    sync_rc=0
    sync_repo "$gl_path" "$gl_name" || sync_rc=$?
    if [[ $sync_rc -eq 0 ]]; then
      info "✅ ${gl_name} done"
      (( synced++ )) || true
    elif [[ $sync_rc -eq 2 ]]; then
      warn "⚠️  ${gl_name} skipped (access denied)"
      (( skipped++ )) || true
    else
      warn "❌ ${gl_name} failed"
      (( failed++ )) || true
    fi

  done < <(get_subgroup_projects "$group_id")
done

echo ""
info "Complete — synced: ${synced} | skipped: ${skipped} | failed: ${failed}"
budget_report
[ "$failed" -eq 0 ] || exit 1
