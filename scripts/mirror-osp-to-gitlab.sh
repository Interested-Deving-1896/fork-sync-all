#!/usr/bin/env bash
#
# Mirrors every repo in OSP_ORG (OpenOS-Project-OSP) to its GitLab counterpart
# under openos-project, creating the GitLab project if it doesn't exist yet.
#
# Repo → subgroup placement is driven by config/gitlab-subgroups.yml.
# Edit that file to add repos, move repos between subgroups, or add subgroups.
# Any repo not listed there falls back to the ops subgroup.
#
# Push strategy: bare-clone from GitHub, push +refs/heads/* +refs/tags/* to
# GitLab. GitLab-only branches (all-features, openos/ci, feat/*, lts) are
# never deleted because we don't use --mirror prune.
#
# Required env vars:
#   GH_TOKEN      — GitHub PAT with repo read scope
#   GITLAB_TOKEN  — GitLab PAT with api + write_repository scope on the target group
#   OSP_ORG       — GitHub org to mirror from (default: OpenOS-Project-OSP)
#
# Optional env vars:
#   GITLAB_GROUP      — GitLab root group to mirror into (default: openos-project)
#   SUBGROUPS_CONFIG  — path to subgroup placement config (default: config/gitlab-subgroups.yml)

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${OSP_ORG:=OpenOS-Project-OSP}"
GITLAB_GROUP="${GITLAB_GROUP:-openos-project}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/branch-name-conv.sh
source "${SCRIPT_DIR}/branch-name-conv.sh"

# GITLAB_TOKEN is required but may be absent while the GitLab account is
# pending reinstatement. Exit 0 (skip) rather than 1 (failure) so the
# workflow does not generate CI failure notifications in the interim.

# ── Budget guard ─────────────────────────────────────────────────────────────
source "$(dirname "${BASH_SOURCE[0]}")/includes/budget.sh"
budget_init

if [ -z "${GITLAB_TOKEN:-}" ]; then
  echo "[mirror-osp-to-gitlab] GITLAB_TOKEN is not set — skipping."
  echo "  Set it with: gh secret set GITLAB_SYNC_TOKEN --repo OpenOS-Project-OSP/fork-sync-all"
  exit 0
fi

GL_API="https://gitlab.com/api/v4"
# shellcheck disable=SC2034
GH_API="https://api.github.com"

# ── Subgroup map — loaded from config/gitlab-subgroups.yml ───────────────────
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# Resolve to absolute path now — the script later does `cd "$work_dir"` into a
# git mirror clone, which would break any relative path passed via SUBGROUPS_CONFIG.
_raw_sg_config="${SUBGROUPS_CONFIG:-config/gitlab-subgroups.yml}"
if [[ "${_raw_sg_config}" != /* ]]; then
  GL_SUBGROUP_CONFIG="${REPO_ROOT}/${_raw_sg_config}"
else
  GL_SUBGROUP_CONFIG="${_raw_sg_config}"
fi

if [[ ! -f "${GL_SUBGROUP_CONFIG}" ]]; then
  echo "ERROR: ${GL_SUBGROUP_CONFIG} not found" >&2
  exit 1
fi

# gl_subgroup_lookup <repo_name>
# Prints "namespace_id|subgroup_name|path" for the given repo, or the default.
gl_subgroup_lookup() {
  python3 - "$1" "${GL_SUBGROUP_CONFIG}" "${GITLAB_GROUP}" << 'PYEOF'
import sys, yaml

repo        = sys.argv[1]
config_path = sys.argv[2]
gl_group    = sys.argv[3]  # e.g. openos-project or openos-project-ooc-ecosystem

with open(config_path) as f:
    config = yaml.safe_load(f)

default_sg_name = config.get("default_subgroup", "ops")
subgroups       = config.get("subgroups", {}) or {}

# Search for the repo in the subgroup map
for sg_name, sg in subgroups.items():
    if repo in (sg.get("repos") or []):
        ns_id = sg.get("id", 0)
        path  = sg.get("path") or f"{gl_group}/{sg_name}"
        print(f"{ns_id}|{sg_name}|{path}")
        sys.exit(0)

# Not found — use default subgroup
if default_sg_name in subgroups:
    sg    = subgroups[default_sg_name]
    ns_id = sg.get("id", 0)
    path  = sg.get("path") or f"{gl_group}/{default_sg_name}"
    print(f"{ns_id}|{default_sg_name}|{path}")
    sys.exit(0)

# Hard fallback — use root group itself
print(f"0|root|{gl_group}")
PYEOF
}

# Repos to skip entirely (no GitLab mirror needed).
# Add repo names here to permanently exclude them from mirroring.
#
# Note: org-mirror (openos-project/ops/org-mirror) is NOT excluded — it is
# mirrored normally. gl_ensure_force_push() handles branch protection
# automatically before each push. Do not add it here unless you want to
# stop mirroring it entirely.
EXCLUDED_REPOS=()

info() { echo "[mirror-osp-to-gitlab] $*" >&2; }
warn() { echo "[warn] $*" >&2; }

# ── API helpers with rate-limit retry ────────────────────────────────────────
# GitLab REST limit: 2 000 req/min per token (RateLimit-Reset header, epoch).
# GitHub REST limit: 5 000 req/hr (X-RateLimit-Reset header, epoch).
# Both return HTTP 429 when exceeded; GitLab also uses 403 for some limits.
# git push failures are retried separately with exponential backoff.
_MOG_HEADER=$(mktemp)
trap 'rm -f "$_MOG_HEADER"' EXIT

gl_api() {
  local method="${1:-GET}" url="$2"; shift 2
  local max_retries=3 attempt=0
  while true; do
    local out http_code
    out=$(curl -sf -w "\n%{http_code}" -X "$method" \
      -D "$_MOG_HEADER" \
      --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
      "$@" "$url" 2>/dev/null) || true
    http_code=$(echo "$out" | tail -1)
    if [[ "$http_code" == "429" || "$http_code" == "403" ]]; then
      (( attempt++ )) || true
      if (( attempt > max_retries )); then echo "$out" | sed '$d'; return 1; fi
      local reset now wait
      reset=$(grep -i "ratelimit-reset:" "$_MOG_HEADER" 2>/dev/null | tr -d '\r' | awk '{print $2}')
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

gh_api_list() {
  local url="$1"
  local max_retries=3 attempt=0
  while true; do
    local out http_code
    out=$(curl -sf -w "\n%{http_code}" \
      -D "$_MOG_HEADER" \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      "$url" 2>/dev/null) || true
    http_code=$(echo "$out" | tail -1)
    if [[ "$http_code" == "429" || "$http_code" == "403" ]]; then
      (( attempt++ )) || true
      if (( attempt > max_retries )); then echo "$out" | sed '$d'; return 1; fi
      local reset now wait
      reset=$(grep -i "x-ratelimit-reset:" "$_MOG_HEADER" 2>/dev/null | tr -d '\r' | awk '{print $2}')
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
    echo "$out" | sed '$d'
    [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]] || return 1
    return 0
  done
}

git_push_retry() {
  local remote="$1" refspec="$2" max_retries=3 attempt=0
  while true; do
    if git push "$remote" "$refspec" 2>&1 \
        | sed "s/${GH_TOKEN}/***TOKEN***/g" \
        | sed "s/${GITLAB_TOKEN}/***TOKEN***/g"; then
      return 0
    fi
    (( attempt++ )) || true
    if (( attempt > max_retries )); then return 1; fi
    local wait=$(( attempt * 15 ))
    warn "[push-retry] attempt ${attempt}/${max_retries} failed — retrying in ${wait}s"
    sleep "$wait"
  done
}

is_excluded() {
  local name="$1"
  for ex in "${EXCLUDED_REPOS[@]+"${EXCLUDED_REPOS[@]}"}"; do
    [[ "$name" == "$ex" ]] && return 0
  done
  return 1
}

# Returns the GitLab project HTTP URL if it exists, empty string if not
gl_project_url() {
  local namespace_path="$1"
  local encoded
  encoded=$(printf '%s' "$namespace_path" | sed 's|/|%2F|g')
  local result
  result=$(gl_api GET "${GL_API}/projects/${encoded}") || true
  echo "$result" | grep -o '"http_url_to_repo":"[^"]*"' | sed 's/"http_url_to_repo":"//;s/"//'
}

# Creates a GitLab project under the given namespace_id, returns HTTP URL
gl_create_project() {
  local name="$1" namespace_id="$2"
  info "  Creating GitLab project '${name}' in namespace ${namespace_id} ..." >&2
  local result
  result=$(gl_api POST "${GL_API}/projects" \
    --header "Content-Type: application/json" \
    --data "{\"name\":\"${name}\",\"path\":\"${name}\",\"namespace_id\":${namespace_id},\"visibility\":\"public\",\"initialize_with_readme\":false}") || true
  echo "$result" | grep -o '"http_url_to_repo":"[^"]*"' | sed 's/"http_url_to_repo":"//;s/"//'
}

# Ensures allow_force_push=true on every protected branch of a GitLab project.
# The mirror uses force-push (+refs/heads/...) so any protected branch with
# allow_force_push=false will reject the push. This function unprotects and
# re-protects each branch with force-push enabled.
# $1 = namespace_path (e.g. openos-project/neon-deving/KPort)
gl_ensure_force_push() {
  local namespace_path="$1"
  local encoded
  encoded=$(printf '%s' "$namespace_path" | sed 's|/|%2F|g')

  local branches_json
  branches_json=$(gl_api GET "${GL_API}/projects/${encoded}/protected_branches") || return 0
  # If no protected branches, nothing to do
  echo "$branches_json" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d else 1)" 2>/dev/null || return 0

  while IFS= read -r branch_name; do
    [[ -z "$branch_name" ]] && continue
    local branch_encoded
    branch_encoded=$(printf '%s' "$branch_name" | sed 's|/|%2F|g')

    # Check if force_push is already enabled
    local force_push
    force_push=$(echo "$branches_json" | python3 -c "
import sys, json
branches = json.load(sys.stdin)
for b in branches:
    if b['name'] == sys.argv[1]:
        print('true' if b.get('allow_force_push') else 'false')
        break
" "$branch_name" 2>/dev/null)

    [[ "$force_push" == "true" ]] && continue

    info "  Enabling force-push on protected branch '${branch_name}' ..."

    # Unprotect first (DELETE), then re-protect with allow_force_push=true
    gl_api DELETE "${GL_API}/projects/${encoded}/protected_branches/${branch_encoded}" > /dev/null 2>&1 || true
    gl_api POST "${GL_API}/projects/${encoded}/protected_branches" \
      --header "Content-Type: application/json" \
      --data "{\"name\":\"${branch_name}\",\"push_access_level\":40,\"merge_access_level\":40,\"allow_force_push\":true}" \
      > /dev/null || warn "  Could not re-protect branch '${branch_name}' — push may fail"

  done < <(echo "$branches_json" | python3 -c "
import sys, json
for b in json.load(sys.stdin):
    if not b.get('allow_force_push'):
        print(b['name'])
" 2>/dev/null)
}

get_osp_repos() {
  # Single GraphQL call regardless of repo count — replaces paginated REST.
  # Falls back to paginated REST if GraphQL fails.
  local cursor="" has_next=true names=""

  while [[ "$has_next" == "true" ]]; do
    local after_arg=""
    [[ -n "$cursor" ]] && after_arg=", after: \\\"${cursor}\\\""
    local result
    result=$(curl -sf \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "Content-Type: application/json" \
      "${GH_API}/graphql" \
      -d "{\"query\":\"{ organization(login: \\\"${OSP_ORG}\\\") { repositories(first: 100${after_arg}) { nodes { name } pageInfo { hasNextPage endCursor } } } }\"}" \
      2>/dev/null || echo "{}")

    local page_names
    page_names=$(echo "$result" | python3 -c "
import json, sys
d = json.load(sys.stdin)
repos = d.get('data', {}).get('organization', {}).get('repositories', {})
for n in repos.get('nodes', []):
    print(n['name'])
" 2>/dev/null || echo "")

    names+="${page_names}"$'\n'

    has_next=$(echo "$result" | python3 -c "
import json, sys
d = json.load(sys.stdin)
pi = d.get('data', {}).get('organization', {}).get('repositories', {}).get('pageInfo', {})
print('true' if pi.get('hasNextPage') else 'false')
" 2>/dev/null || echo "false")

    cursor=$(echo "$result" | python3 -c "
import json, sys
d = json.load(sys.stdin)
pi = d.get('data', {}).get('organization', {}).get('repositories', {}).get('pageInfo', {})
print(pi.get('endCursor', ''))
" 2>/dev/null || echo "")

    [[ "$has_next" != "true" ]] && break
  done

  echo "$names" | grep -E '^[A-Za-z0-9._-]+$'
}

mirror_repo() {
  local gh_name="$1" gl_url="$2" gl_ns_path="$3"

  local gh_clone_url="https://x-access-token:${GH_TOKEN}@github.com/${OSP_ORG}/${gh_name}.git"
  local gl_auth_url="${gl_url/https:\/\//https://oauth2:${GITLAB_TOKEN}@}"

  local work_dir
  work_dir=$(mktemp -d)

  info "  Cloning github.com/${OSP_ORG}/${gh_name} ..."
  if ! git clone --mirror "$gh_clone_url" "$work_dir" 2>&1 \
       | sed "s/${GH_TOKEN}/***TOKEN***/g"; then
    warn "  Clone failed"
    rm -rf "$work_dir"
    return 1
  fi

  # Ensure force-push is allowed on all protected branches before pushing.
  # GitLab creates a default branch protection on new projects; the mirror
  # uses force-push (+refs/heads/...) which is blocked unless explicitly enabled.
  gl_ensure_force_push "$gl_ns_path"

  cd "$work_dir" || exit 1

  local push_ok=true
  local attempt=0 max_retries=3
  while true; do
    if push_branches_encoded "$gl_auth_url" 2>&1 \
        | sed "s/${GITLAB_TOKEN}/***TOKEN***/g" \
        | sed "s/${GH_TOKEN}/***TOKEN***/g"; then
      break
    fi
    (( attempt++ )) || true
    if (( attempt > max_retries )); then
      warn "Branch push failed after ${max_retries} attempts"
      push_ok=false
      break
    fi
    local wait=$(( attempt * 15 ))
    warn "[push-retry] attempt ${attempt}/${max_retries} failed — retrying in ${wait}s"
    sleep "$wait"
  done

  git push "$gl_auth_url" '+refs/tags/*:refs/tags/*' 2>&1 \
    | sed "s/${GITLAB_TOKEN}/***TOKEN***/g" \
    || true   # tag failures non-fatal

  cd /
  rm -rf "$work_dir"

  $push_ok
}

# ── Filters (from workflow_dispatch inputs) ───────────────────────────────────
# REPO_FILTER:     substring — only process repos whose name contains this string
# SUBGROUP_FILTER: exact subgroup name — only process repos in this subgroup
# DRY_RUN:         'true' — print actions without pushing or creating projects
REPO_FILTER="${REPO_FILTER:-}"
SUBGROUP_FILTER="${SUBGROUP_FILTER:-}"
DRY_RUN="${DRY_RUN:-false}"

[[ -n "$REPO_FILTER" ]]     && info "Repo filter:     '${REPO_FILTER}'"
[[ -n "$SUBGROUP_FILTER" ]] && info "Subgroup filter: '${SUBGROUP_FILTER}'"
[[ "$DRY_RUN" == "true" ]]  && info "Dry run: no pushes or project creation will occur"

# ── main ─────────────────────────────────────────────────────────────────────

synced=0
failed=0
skipped=0

info "Fetching repos from ${OSP_ORG} ..."
mapfile -t osp_repos < <(get_osp_repos)
info "Found ${#osp_repos[@]} repos."
echo ""

for name in "${osp_repos[@]}"; do
    budget_check "$name" || break
  [[ -z "$name" ]] && continue

  if is_excluded "$name"; then
    (( skipped++ )) || true
    continue
  fi

  # Apply repo name substring filter
  if [[ -n "$REPO_FILTER" && "$name" != *"$REPO_FILTER"* ]]; then
    (( skipped++ )) || true
    continue
  fi

  # Determine target subgroup from config/gitlab-subgroups.yml
  lookup=$(gl_subgroup_lookup "$name")
  namespace_id="${lookup%%|*}"
  subgroup_name="${lookup#*|}"; subgroup_name="${subgroup_name%%|*}"
  subgroup_path="${lookup##*|}"
  ns_path="${subgroup_path}/${name}"

  # Apply subgroup filter ("all" or empty means no filter)
  if [[ -n "$SUBGROUP_FILTER" && "$SUBGROUP_FILTER" != "all" && "$subgroup_name" != "$SUBGROUP_FILTER" ]]; then
    (( skipped++ )) || true
    continue
  fi

  info "──────────────────────────────────────────"
  info "github.com/${OSP_ORG}/${name}  →  gitlab.com/${ns_path}"

  if [[ "$DRY_RUN" == "true" ]]; then
    info "  DRY  would mirror ${name}"
    (( synced++ )) || true
    continue
  fi

  # Check if GitLab project exists; create if not
  gl_http_url=$(gl_project_url "$ns_path")
  if [[ -z "$gl_http_url" ]]; then
    gl_http_url=$(gl_create_project "$name" "$namespace_id")
    if [[ -z "$gl_http_url" ]]; then
      warn "  Could not create GitLab project — skipping (token may lack create permission)"
      (( skipped++ )) || true
      continue
    fi
    info "  Created: ${gl_http_url}"
    # Brief pause to let GitLab finish initialising the repo
    sleep 3
  fi

  if mirror_repo "$name" "$gl_http_url" "$ns_path"; then
    info "✅ ${name} done"
    (( synced++ )) || true
  else
    warn "❌ ${name} failed"
    (( failed++ )) || true
  fi
done

echo ""
info "Complete — synced: ${synced} | skipped: ${skipped} | failed: ${failed}"
budget_report
[ "$failed" -eq 0 ] || exit 1
