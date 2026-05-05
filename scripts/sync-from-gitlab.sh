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
: "${GITHUB_OWNER:=Interested-Deving-1896}"

GL_API="https://gitlab.com/api/v4"
GH_API="https://api.github.com"

# Subgroup IDs to scan (all openos-project subgroups that hold OSP-equivalent repos)
SUBGROUP_IDS=(
  130516402   # penguins-eggs_deving
  130516465   # immutable-filesystem_deving
  130516536   # incus_deving
  130516188   # linux-kernel_filesystem_deving
  130734009   # ops
)

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

info() { echo "[sync-from-gitlab] $*"; }
warn() { echo "[warn] $*" >&2; }

# ── API helpers with rate-limit retry ────────────────────────────────────────
# GitLab REST limit: 2 000 req/min per token (RateLimit-Reset header, epoch).
# GitHub REST limit: 5 000 req/hr (X-RateLimit-Reset header, epoch).
# Both return HTTP 429 when exceeded; GitLab also uses 403 for some limits.
_SF_HEADER=$(mktemp)
trap 'rm -f "$_SF_HEADER"' EXIT

gl_api_get() {
  local max_retries=3 attempt=0
  while true; do
    local out http_code
    out=$(curl -sf -w "\n%{http_code}" \
      -D "$_SF_HEADER" \
      --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
      "$@" 2>/dev/null) || true
    http_code=$(echo "$out" | tail -1)
    if [[ "$http_code" == "429" || "$http_code" == "403" ]]; then
      (( attempt++ )) || true
      if (( attempt > max_retries )); then echo "$out" | sed '$d'; return 1; fi
      local reset now wait
      reset=$(grep -i "ratelimit-reset:" "$_SF_HEADER" 2>/dev/null | tr -d '\r' | awk '{print $2}')
      now=$(date +%s); wait=$(( ${reset:-0} - now + 5 ))
      if [[ -n "$reset" && "$wait" -gt 0 && "$wait" -lt 3700 ]]; then
        warn "[rate-limit] GitLab HTTP ${http_code} — sleeping ${wait}s (attempt ${attempt}/${max_retries})"
        sleep "$wait"
      else
        warn "[rate-limit] GitLab HTTP ${http_code} — backing off 60s (attempt ${attempt}/${max_retries})"
        sleep 60
      fi
      continue
    fi
    echo "$out" | sed '$d'
    [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]] || return 1
    return 0
  done
}

gh_api_check() {
  # Lightweight GitHub existence check with rate-limit awareness
  local url="$1"
  local max_retries=3 attempt=0
  while true; do
    local http_code
    http_code=$(curl -sf -o /dev/null -w "%{http_code}" \
      -D "$_SF_HEADER" \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      "$url" 2>/dev/null) || true
    if [[ "$http_code" == "429" || "$http_code" == "403" ]]; then
      (( attempt++ )) || true
      if (( attempt > max_retries )); then echo "$http_code"; return 1; fi
      local reset now wait
      reset=$(grep -i "x-ratelimit-reset:" "$_SF_HEADER" 2>/dev/null | tr -d '\r' | awk '{print $2}')
      now=$(date +%s); wait=$(( ${reset:-0} - now + 5 ))
      if [[ -n "$reset" && "$wait" -gt 0 && "$wait" -lt 3700 ]]; then
        warn "[rate-limit] GitHub HTTP ${http_code} — sleeping ${wait}s (attempt ${attempt}/${max_retries})"
        sleep "$wait"
      else
        warn "[rate-limit] GitHub HTTP ${http_code} — backing off 60s (attempt ${attempt}/${max_retries})"
        sleep 60
      fi
      continue
    fi
    echo "$http_code"
    return 0
  done
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
  while true; do
    local result count
    result=$(gl_api_get "${GL_API}/groups/${group_id}/projects?per_page=100&page=${page}&simple=true") || break
    count=$(echo "$result" | grep -o '"id"' | wc -l)
    [[ "$count" -eq 0 ]] && break
    # Output: "gl_project_id|repo_name|gl_path_with_namespace"
    echo "$result" | grep -oE '"id":[0-9]+,"description"[^}]*"path":"[^"]+","path_with_namespace":"[^"]+"' | \
      sed 's/"id":\([0-9]*\).*"path":"\([^"]*\)","path_with_namespace":"\([^"]*\)"/\1|\2|\3/'
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

  local gl_url="https://oauth2:${GITLAB_TOKEN}@gitlab.com/${gl_path}.git"
  local gh_url="https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_OWNER}/${gh_name}.git"

  local work_dir
  work_dir=$(mktemp -d)

  info "  Cloning gitlab.com/${gl_path} ..."
  if ! git clone --mirror "$gl_url" "$work_dir" 2>&1; then
    warn "  Clone failed for ${gl_path}"
    rm -rf "$work_dir"
    return 1
  fi

  cd "$work_dir"

  local push_ok=true

  # Push all branches force — preserves GitHub-only refs (no prune)
  git push "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_OWNER}/${gh_name}.git" \
    '+refs/heads/*:refs/heads/*' 2>&1 \
    | sed "s/${GH_TOKEN}/***TOKEN***/g" \
    | sed "s/${GITLAB_TOKEN}/***TOKEN***/g" \
    || push_ok=false

  # Push tags (non-fatal if some already exist)
  git push "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_OWNER}/${gh_name}.git" \
    '+refs/tags/*:refs/tags/*' 2>&1 \
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
  info "Scanning subgroup ${group_id} ..."

  while IFS='|' read -r _gl_id gl_name gl_path; do
    [[ -z "$gl_name" ]] && continue

    if is_excluded "$gl_name"; then
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

    if sync_repo "$gl_path" "$gl_name"; then
      info "✅ ${gl_name} done"
      (( synced++ )) || true
    else
      warn "❌ ${gl_name} failed"
      (( failed++ )) || true
    fi

  done < <(get_subgroup_projects "$group_id")
done

echo ""
info "Complete — synced: ${synced} | skipped: ${skipped} | failed: ${failed}"
[ "$failed" -eq 0 ] || exit 1
