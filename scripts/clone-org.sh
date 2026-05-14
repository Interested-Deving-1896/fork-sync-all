#!/usr/bin/env bash
#
# Clones all repositories from an org/user on any supported git platform
# into a target GitHub org, optionally registering each for ongoing sync.
#
# Inspired by gabrie30/ghorg — reimplemented natively for GitHub Actions
# without requiring a Go binary on the runner.
#
# Supported source platforms:
#   github    — GitHub.com or GitHub Enterprise
#   gitlab    — GitLab.com or self-hosted
#   bitbucket — Bitbucket Cloud
#   gitea     — any Gitea instance
#
# Required env vars:
#   GH_TOKEN        — GitHub PAT (repo + admin:org + workflow scopes)
#   SOURCE_PLATFORM — github | gitlab | bitbucket | gitea
#   SOURCE_ORG      — org or user name on the source platform
#   TARGET_ORG      — GitHub org to clone repos into (default: Interested-Deving-1896)
#
# Optional env vars:
#   SOURCE_TOKEN    — PAT for the source platform (required for private repos)
#   SOURCE_BASE_URL — base URL for self-hosted instances (e.g. https://gitlab.example.com)
#   CLONE_TYPE      — org | user (default: org)
#   SKIP_FORKS      — true | false (default: false)
#   SKIP_ARCHIVED   — true | false (default: false)
#   SKIP_PRIVATE    — true | false (default: false)
#   INCLUDE_FILTER  — regex: only clone repos whose names match
#   EXCLUDE_FILTER  — regex: skip repos whose names match
#   ONGOING_SYNC    — true | false — register each repo in registered-imports.json
#   MIRROR_TO_OSP   — true | false — push each repo through OSP→OOC chain
#   CONCURRENCY     — max parallel clones (default: 5)
#   CLONE_DEPTH     — shallow clone depth (default: full)
#   BACKUP_MODE     — true | false — bare mirror clone, no working copy

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${SOURCE_PLATFORM:?SOURCE_PLATFORM is required (github|gitlab|bitbucket|gitea)}"
: "${SOURCE_ORG:?SOURCE_ORG is required}"

TARGET_ORG="${TARGET_ORG:-Interested-Deving-1896}"
SOURCE_BASE_URL="${SOURCE_BASE_URL:-}"

# ── Credential resolution ─────────────────────────────────────────────────────
# SOURCE_CREDENTIAL may be set to a specific secret name by the workflow input,
# or left as "(auto — use platform default)" / empty to use the platform default.
# The workflow passes all secrets as _SECRET_<NAME> env vars so we can resolve
# them here without hardcoding a single secret name.
_resolve_source_token() {
  local override="${SOURCE_CREDENTIAL:-}"
  # Strip the auto-select sentinel
  [[ "$override" == "(auto — use platform default)" ]] && override=""

  if [[ -n "$override" ]]; then
    # Caller selected a specific secret — look it up from _SECRET_<NAME>
    local var="_SECRET_${override}"
    local val="${!var:-}"
    if [[ -z "$val" ]]; then
      warn "SOURCE_CREDENTIAL='${override}' but _SECRET_${override} is empty or unset — falling back to platform default"
    else
      echo "$val"
      return
    fi
  fi

  # Platform defaults
  case "${SOURCE_PLATFORM}" in
    github)    echo "${_SECRET_SYNC_TOKEN:-${GH_TOKEN}}" ;;
    gitlab)    echo "${_SECRET_GITLAB_SYNC_TOKEN:-}" ;;
    bitbucket) echo "${_SECRET_BITBUCKET_TOKEN:-}" ;;
    gitea)     echo "${_SECRET_GITEA_TOKEN:-}" ;;
    *)         echo "" ;;
  esac
}

SOURCE_TOKEN="$(_resolve_source_token)"
CLONE_TYPE="${CLONE_TYPE:-org}"
SKIP_FORKS="${SKIP_FORKS:-false}"
SKIP_ARCHIVED="${SKIP_ARCHIVED:-false}"
SKIP_PRIVATE="${SKIP_PRIVATE:-false}"
INCLUDE_FILTER="${INCLUDE_FILTER:-}"
EXCLUDE_FILTER="${EXCLUDE_FILTER:-}"
ONGOING_SYNC="${ONGOING_SYNC:-false}"
MIRROR_TO_OSP="${MIRROR_TO_OSP:-false}"
CONCURRENCY="${CONCURRENCY:-5}"
CLONE_DEPTH="${CLONE_DEPTH:-}"
BACKUP_MODE="${BACKUP_MODE:-false}"

GH_API="https://api.github.com"

info()  { echo "[clone-org] $*"; }
warn()  { echo "[clone-org][warn] $*" >&2; }
error() { echo "[clone-org][error] $*" >&2; exit 1; }
sanitize_tokens() {
  local out="$1"
  [[ -n "$GH_TOKEN" ]]     && out="${out//${GH_TOKEN}/***TOKEN***}"
  [[ -n "$SOURCE_TOKEN" ]] && out="${out//${SOURCE_TOKEN}/***TOKEN***}"
  echo "$out"
}

gh_api() {
  curl -sf \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "$@"
}

# ── Platform-specific repo listing ───────────────────────────────────────────

list_github_repos() {
  local base="${SOURCE_BASE_URL:-https://api.github.com}"
  local token="${SOURCE_TOKEN:-$GH_TOKEN}"
  local page=1
  while true; do
    local url
    if [[ "$CLONE_TYPE" == "user" ]]; then
      url="${base}/users/${SOURCE_ORG}/repos?per_page=100&page=${page}"
    else
      url="${base}/orgs/${SOURCE_ORG}/repos?per_page=100&page=${page}"
    fi
    local result
    result=$(curl -sf \
      -H "Authorization: token ${token}" \
      -H "Accept: application/vnd.github+json" \
      "$url") || break
    local count
    count=$(echo "$result" | python3 -c "import json,sys; repos=json.load(sys.stdin); print(len(repos))" 2>/dev/null || echo 0)
    [[ "$count" -eq 0 ]] && break
    echo "$result" | python3 -c "
import json,sys
repos = json.load(sys.stdin)
for r in repos:
    fork     = str(r.get('fork', False)).lower()
    archived = str(r.get('archived', False)).lower()
    private  = str(r.get('private', False)).lower()
    clone_url = r.get('clone_url','')
    ssh_url   = r.get('ssh_url','')
    print(f\"{r['name']}|{fork}|{archived}|{private}|{clone_url}|{ssh_url}\")
"
    (( page++ ))
  done
}

list_gitlab_repos() {
  local base="${SOURCE_BASE_URL:-https://gitlab.com}"
  local token="${SOURCE_TOKEN:-}"
  local page=1
  local entity_type="groups"
  [[ "$CLONE_TYPE" == "user" ]] && entity_type="users"
  while true; do
    local result
    result=$(curl -sf \
      ${token:+-H "PRIVATE-TOKEN: ${token}"} \
      "${base}/api/v4/${entity_type}/${SOURCE_ORG}/projects?per_page=100&page=${page}&include_subgroups=true") || break
    local count
    count=$(echo "$result" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
    [[ "$count" -eq 0 ]] && break
    echo "$result" | python3 -c "
import json,sys
repos = json.load(sys.stdin)
for r in repos:
    fork     = 'true' if r.get('forked_from_project') else 'false'
    archived = str(r.get('archived', False)).lower()
    private  = 'true' if r.get('visibility','') == 'private' else 'false'
    clone_url = r.get('http_url_to_repo','')
    ssh_url   = r.get('ssh_url_to_repo','')
    print(f\"{r['path']}|{fork}|{archived}|{private}|{clone_url}|{ssh_url}\")
"
    (( page++ ))
  done
}

list_bitbucket_repos() {
  local token="${SOURCE_TOKEN:-}"
  local url="https://api.bitbucket.org/2.0/repositories/${SOURCE_ORG}?pagelen=100"
  while [[ -n "$url" ]]; do
    local result
    result=$(curl -sf \
      ${token:+-H "Authorization: Bearer ${token}"} \
      "$url") || break
    echo "$result" | python3 -c "
import json,sys
data = json.load(sys.stdin)
for r in data.get('values',[]):
    fork     = 'true' if r.get('parent') else 'false'
    archived = 'false'
    private  = 'true' if r.get('is_private') else 'false'
    clone_url = next((l['href'] for l in r.get('links',{}).get('clone',[]) if l.get('name')=='https'), '')
    ssh_url   = next((l['href'] for l in r.get('links',{}).get('clone',[]) if l.get('name')=='ssh'), '')
    print(f\"{r['slug']}|{fork}|{archived}|{private}|{clone_url}|{ssh_url}\")
"
    url=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('next',''))" 2>/dev/null || echo "")
  done
}

list_gitea_repos() {
  local base="${SOURCE_BASE_URL:?SOURCE_BASE_URL required for gitea}"
  local token="${SOURCE_TOKEN:-}"
  local page=1
  local entity="orgs"
  [[ "$CLONE_TYPE" == "user" ]] && entity="users"
  while true; do
    local result
    result=$(curl -sf \
      ${token:+-H "Authorization: token ${token}"} \
      "${base}/api/v1/${entity}/${SOURCE_ORG}/repos?limit=50&page=${page}") || break
    local count
    count=$(echo "$result" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
    [[ "$count" -eq 0 ]] && break
    echo "$result" | python3 -c "
import json,sys
repos = json.load(sys.stdin)
for r in repos:
    fork     = str(r.get('fork', False)).lower()
    archived = str(r.get('archived', False)).lower()
    private  = str(r.get('private', False)).lower()
    clone_url = r.get('clone_url','')
    ssh_url   = r.get('ssh_url','')
    print(f\"{r['name']}|{fork}|{archived}|{private}|{clone_url}|{ssh_url}\")
"
    (( page++ ))
  done
}

# ── Repo filtering ────────────────────────────────────────────────────────────

should_skip() {
  local name="$1" is_fork="$2" is_archived="$3" is_private="$4"
  [[ "$SKIP_FORKS"    == "true" && "$is_fork"     == "true" ]] && return 0
  [[ "$SKIP_ARCHIVED" == "true" && "$is_archived" == "true" ]] && return 0
  [[ "$SKIP_PRIVATE"  == "true" && "$is_private"  == "true" ]] && return 0
  [[ -n "$INCLUDE_FILTER" ]] && ! echo "$name" | grep -qE "$INCLUDE_FILTER" && return 0
  [[ -n "$EXCLUDE_FILTER" ]] &&   echo "$name" | grep -qE "$EXCLUDE_FILTER" && return 0
  return 1
}

# ── Single repo clone + push ──────────────────────────────────────────────────

clone_and_push() {
  local name="$1" clone_url="$2"
  local work_dir
  work_dir=$(mktemp -d)
  trap "rm -rf '${work_dir}'" RETURN

  info "  Cloning ${clone_url} ..."

  # Inject source token into URL if provided
  local auth_url="$clone_url"
  if [[ -n "$SOURCE_TOKEN" && "$clone_url" == https://* ]]; then
    auth_url="${clone_url/https:\/\//https://oauth2:${SOURCE_TOKEN}@}"
  fi

  local clone_args=(--mirror)
  [[ -n "$CLONE_DEPTH" ]] && clone_args+=(--depth "$CLONE_DEPTH")

  if ! git clone "${clone_args[@]}" "$auth_url" "$work_dir" 2>&1 \
      | sed "s/${SOURCE_TOKEN:-NOTOKEN}/***TOKEN***/g" \
      | sed "s/${GH_TOKEN}/***TOKEN***/g"; then
    warn "  Clone failed for ${name}"
    return 1
  fi

  # Create target repo in GitHub if it doesn't exist
  local exists
  exists=$(gh_api "${GH_API}/repos/${TARGET_ORG}/${name}" 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('name',''))" 2>/dev/null || echo "")

  if [[ -z "$exists" ]]; then
    info "  Creating ${TARGET_ORG}/${name} on GitHub ..."
    gh_api -X POST "${GH_API}/orgs/${TARGET_ORG}/repos" \
      -d "{\"name\":\"${name}\",\"private\":false,\"auto_init\":false}" \
      > /dev/null || { warn "  Failed to create ${TARGET_ORG}/${name}"; return 1; }
  fi

  local target_url="https://${GH_TOKEN}@github.com/${TARGET_ORG}/${name}.git"

  cd "$work_dir"

  # Source branch-name-conv.sh for platform-safe push
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=scripts/branch-name-conv.sh
  source "${script_dir}/branch-name-conv.sh"

  local push_ok=true
  push_branches_encoded "$target_url" 2>&1 \
    | sed "s/${GH_TOKEN}/***TOKEN***/g" \
    || push_ok=false

  git push "$target_url" '+refs/tags/*:refs/tags/*' 2>&1 \
    | sed "s/${GH_TOKEN}/***TOKEN***/g" \
    || true  # tag failures non-fatal

  cd /

  $push_ok || return 1

  # Register for ongoing sync if requested
  if [[ "$ONGOING_SYNC" == "true" ]]; then
    info "  Registering ${name} for ongoing sync ..."
    local json_file="${GITHUB_WORKSPACE:-/workspaces/fork-sync-all}/registered-imports.json"
    if [[ -f "$json_file" ]]; then
      python3 -c "
import json, sys
path = '${json_file}'
entry = '${clone_url}'
data = json.load(open(path))
if entry not in data:
    data.append(entry)
    json.dump(data, open(path,'w'), indent=2)
    print('  Registered.')
else:
    print('  Already registered.')
"
    fi
  fi

  return 0
}

# ── Main ──────────────────────────────────────────────────────────────────────

info "Listing repos for ${SOURCE_PLATFORM}/${SOURCE_ORG} ..."

repos=()
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  repos+=("$line")
done < <(
  case "$SOURCE_PLATFORM" in
    github)    list_github_repos ;;
    gitlab)    list_gitlab_repos ;;
    bitbucket) list_bitbucket_repos ;;
    gitea)     list_gitea_repos ;;
    *) error "Unsupported platform: ${SOURCE_PLATFORM}" ;;
  esac
)

total=${#repos[@]}
info "Found ${total} repos."
echo ""

cloned=0
skipped=0
failed=0
pids=()
results_dir=$(mktemp -d)

for entry in "${repos[@]}"; do
  IFS='|' read -r name is_fork is_archived is_private clone_url _ssh_url <<< "$entry"

  if should_skip "$name" "$is_fork" "$is_archived" "$is_private"; then
    info "SKIP ${name} (fork=${is_fork} archived=${is_archived} private=${is_private})"
    (( skipped++ ))
    continue
  fi

  info "── ${name} ──"

  # Concurrency: run up to CONCURRENCY clones in parallel
  (
    if clone_and_push "$name" "$clone_url"; then
      echo "ok" > "${results_dir}/${name}"
    else
      echo "fail" > "${results_dir}/${name}"
    fi
  ) &
  pids+=($!)

  # Throttle to CONCURRENCY parallel jobs
  while (( ${#pids[@]} >= CONCURRENCY )); do
    local_pids=()
    for pid in "${pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        local_pids+=("$pid")
      fi
    done
    pids=("${local_pids[@]}")
    (( ${#pids[@]} >= CONCURRENCY )) && sleep 2
  done
done

# Wait for all remaining jobs
for pid in "${pids[@]}"; do
  wait "$pid" 2>/dev/null || true
done

# Tally results
for entry in "${repos[@]}"; do
  name="${entry%%|*}"
  result_file="${results_dir}/${name}"
  [[ -f "$result_file" ]] || continue
  result=$(cat "$result_file")
  if [[ "$result" == "ok" ]]; then
    (( cloned++ ))
  else
    (( failed++ ))
  fi
done

rm -rf "$results_dir"

echo ""
info "Complete — cloned: ${cloned} | skipped: ${skipped} | failed: ${failed}"
[[ "$failed" -eq 0 ]] || exit 1
