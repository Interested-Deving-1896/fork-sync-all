#!/usr/bin/env bash
#
# Injects the "Built with Ona" badge into README.md files across all repos
# in Interested-Deving-1896, OpenOS-Project-OSP, OpenOS-Project-Ecosystem-OOC,
# and the GitLab openos-project group.
#
# Badge format:
#   GitHub:  [![Built with Ona](https://ona.com/build-with-ona.svg)](https://app.ona.com/#https://github.com/<owner>/<repo>)
#   GitLab:  [![Built with Ona](https://ona.com/build-with-ona.svg)](https://app.ona.com/#https://gitlab.com/<group>/<repo>)
#
# The badge is inserted after the first # heading in README.md.
# Repos that already have the badge are skipped (idempotent).
#
# Required env vars:
#   GH_TOKEN      — PAT with repo + read:org scopes on GitHub orgs
#
# Optional env vars:
#   GITLAB_TOKEN  — GitLab PAT with api + write_repository (for GitLab pass)
#   REPO_FILTER   — substring filter on repo name (blank = all)
#   DRY_RUN       — if "true", print actions without committing
#   ORGS          — space-separated list of GitHub orgs to process
#                   (default: all three)
#   SKIP_GITLAB   — if "true", skip the GitLab pass

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"

REPO_FILTER="${REPO_FILTER:-}"
DRY_RUN="${DRY_RUN:-false}"
ORGS="${ORGS:-Interested-Deving-1896 OpenOS-Project-OSP OpenOS-Project-Ecosystem-OOC}"
SKIP_GITLAB="${SKIP_GITLAB:-false}"
GITLAB_TOKEN="${GITLAB_TOKEN:-}"
GITLAB_GROUP="${GITLAB_GROUP:-openos-project}"

GH_API="https://api.github.com"
GL_API="https://gitlab.com/api/v4"
BADGE_SVG="https://ona.com/build-with-ona.svg"
BADGE_BASE="https://app.ona.com/#"


# ── Budget guard ─────────────────────────────────────────────────────────────
source "$(dirname "${BASH_SOURCE[0]}")/includes/budget.sh"
source "$(dirname "${BASH_SOURCE[0]}")/includes/gh-api.sh"
budget_init

info()  { echo "[inject-badges] $*" >&2; }
warn()  { echo "[warn] $*" >&2; }
dry()   { echo "[dry-run] $*" >&2; }

# ── GitHub API helpers ────────────────────────────────────────────────────────

gh_put() {
  curl -sf -X PUT \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    "$@"
}

# Cache: _README_CACHE["owner/repo"] = "sha|base64content"
declare -A _README_CACHE=()

list_gh_repos() {
  # Fetch org repo list + README sha/content via GraphQL (1 call).
  # Populates _README_CACHE for use by get_gh_file — eliminates per-repo REST calls.
  local org="$1"
  local result
  result=$(curl -sf \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Content-Type: application/json" \
    "${GH_API}/graphql" \
    -d "{\"query\":\"{ organization(login: \\\"${org}\\\") { repositories(first: 100, orderBy: {field: NAME, direction: ASC}) { nodes { name object(expression: \\\"HEAD:README.md\\\") { ... on Blob { oid text } } } } } }\"}" \
    2>/dev/null || echo "{}")

  local count
  count=$(echo "$result" | python3 -c "
import json,sys
d=json.load(sys.stdin)
nodes=d.get('data',{}).get('organization',{}).get('repositories',{}).get('nodes',[])
print(len(nodes))
" 2>/dev/null || echo 0)

  if [[ "$count" -gt 0 ]]; then
    # Populate README cache and print repo names
    while IFS='|' read -r name oid text_b64; do
      [[ -z "$name" ]] && continue
      [[ -n "$oid" ]] && _README_CACHE["${org}/${name}"]="${oid}|${text_b64}"
      echo "$name"
    done < <(echo "$result" | python3 -c "
import json, sys, base64
d = json.load(sys.stdin)
nodes = d.get('data',{}).get('organization',{}).get('repositories',{}).get('nodes',[])
for n in nodes:
    name = n.get('name','')
    obj  = n.get('object') or {}
    oid  = obj.get('oid','')
    text = obj.get('text','') or ''
    b64  = base64.b64encode(text.encode()).decode() if text else ''
    print(f'{name}|{oid}|{b64}')
" 2>/dev/null)
    return 0
  fi

  # Fallback: paginated REST (no README cache populated)
  local page=1
  while true; do
    local rest_result rest_count
    rest_result=$(gh_get "${GH_API}/orgs/${org}/repos?per_page=100&page=${page}")
    if echo "$rest_result" | jq -e '.message' > /dev/null 2>&1; then
      warn "GitHub API error for ${org}: $(echo "$rest_result" | jq -r '.message')"
      break
    fi
    rest_count=$(echo "$rest_result" | jq 'length' 2>/dev/null || echo 0)
    [[ "$rest_count" == "0" ]] && break
    echo "$rest_result" | jq -r '.[].name'
    (( page++ ))
  done
}

get_gh_file() {
  local owner="$1" repo="$2" path="$3"
  # Use GraphQL-prefetched README cache when available (README.md only)
  if [[ "$path" == "README.md" ]]; then
    local cached="${_README_CACHE["${owner}/${repo}"]:-}"
    if [[ -n "$cached" ]]; then
      local oid b64
      oid="${cached%%|*}"
      b64="${cached#*|}"
      # Emit a /contents/-compatible JSON blob so callers need no changes
      python3 -c "
import json, sys
oid, b64 = sys.argv[1], sys.argv[2]
# Add newlines every 60 chars to match GitHub API format
content = '\n'.join(b64[i:i+60] for i in range(0, len(b64), 60)) + '\n'
print(json.dumps({'sha': oid, 'content': content, 'encoding': 'base64'}))
" "$oid" "$b64" 2>/dev/null
      return 0
    fi
  fi
  gh_get "${GH_API}/repos/${owner}/${repo}/contents/${path}" 2>/dev/null
}

# ── GitLab API helpers ────────────────────────────────────────────────────────

gl_get() {
  curl -s \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    "$@"
}

gl_put() {
  curl -sf -X PUT \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    -H "Content-Type: application/json" \
    "$@"
}

list_gl_projects() {
  local group="$1" page=1
  while true; do
    local result count
    result=$(gl_get "${GL_API}/groups/${group}/projects?per_page=100&page=${page}&include_subgroups=true")
    count=$(echo "$result" | jq 'length' 2>/dev/null || echo 0)
    [[ "$count" == "0" ]] && break
    echo "$result" | jq -r '.[] | "\(.namespace.full_path)/\(.path)"'
    (( page++ ))
  done
}

# ── Badge helpers ─────────────────────────────────────────────────────────────

make_badge() {
  local url="$1"
  echo "[![Built with Ona](${BADGE_SVG})](${BADGE_BASE}${url})"
}

inject_badge() {
  local content="$1" badge="$2"
  # Insert badge after the first # heading, with a blank line separator
  echo "$content" | awk -v badge="$badge" '
    /^# / && !done { print; print ""; print badge; done=1; next }
    { print }
  '
}

# ── GitHub repo processor ─────────────────────────────────────────────────────

process_gh_repo() {
  local owner="$1" repo="$2"
  [[ -n "$REPO_FILTER" && "$repo" != *"$REPO_FILTER"* ]] && return 0

  local meta
  meta=$(get_gh_file "$owner" "$repo" "README.md") || return 0
  [[ -z "$meta" || "$meta" == "null" ]] && return 0

  # Check for 404
  if echo "$meta" | jq -e '.message' > /dev/null 2>&1; then
    local msg; msg=$(echo "$meta" | jq -r '.message')
    [[ "$msg" == "Not Found" ]] && return 0
    warn "  ${owner}/${repo}: ${msg}"
    return 0
  fi

  local sha content
  sha=$(echo "$meta" | jq -r '.sha // empty')
  content=$(echo "$meta" | jq -r '.content // empty' | tr -d '\n' | base64 -d 2>/dev/null)

  [[ -z "$content" ]] && return 0

  # Already has badge — skip
  if echo "$content" | grep -qF "$BADGE_SVG"; then
    info "  SKIP ${owner}/${repo} (badge already present)"
    return 0
  fi

  local badge target_url
  target_url="https://github.com/${owner}/${repo}"
  badge=$(make_badge "$target_url")
  local new_content
  new_content=$(inject_badge "$content" "$badge")

  if [[ "$DRY_RUN" == "true" ]]; then
    dry "  Would inject badge into ${owner}/${repo}/README.md"
    return 0
  fi

  local new_b64
  new_b64=$(echo "$new_content" | base64 -w0)
  local payload
  payload=$(jq -n \
    --arg msg "docs: add Built with Ona badge [skip ci]" \
    --arg content "$new_b64" \
    --arg sha "$sha" \
    '{message:$msg, content:$content, sha:$sha}')

  if gh_put "${GH_API}/repos/${owner}/${repo}/contents/README.md" -d "$payload" > /dev/null; then
    info "  ✅ Badge injected: ${owner}/${repo}"
  else
    warn "  ❌ Failed: ${owner}/${repo}"
  fi
}

# ── GitLab project processor ──────────────────────────────────────────────────

process_gl_project() {
  local project_path="$1"
  [[ -n "$REPO_FILTER" && "$project_path" != *"$REPO_FILTER"* ]] && return 0

  local encoded_path
  encoded_path=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${project_path}', safe=''))")

  local meta
  meta=$(gl_get "${GL_API}/projects/${encoded_path}/repository/files/README.md?ref=HEAD") || return 0
  [[ -z "$meta" ]] && return 0

  if echo "$meta" | jq -e '.message' > /dev/null 2>&1; then
    local msg; msg=$(echo "$meta" | jq -r '.message')
    [[ "$msg" == "404 File Not Found" || "$msg" == "404 Project Not Found" ]] && return 0
    warn "  GitLab ${project_path}: ${msg}"
    return 0
  fi

  local content ref
  content=$(echo "$meta" | jq -r '.content // empty' | tr -d '\n' | base64 -d 2>/dev/null)
  ref=$(echo "$meta" | jq -r '.ref // "main"')

  [[ -z "$content" ]] && return 0

  if echo "$content" | grep -qF "$BADGE_SVG"; then
    info "  SKIP gitlab:${project_path} (badge already present)"
    return 0
  fi

  local badge target_url
  target_url="https://gitlab.com/${project_path}"
  badge=$(make_badge "$target_url")
  local new_content
  new_content=$(inject_badge "$content" "$badge")

  if [[ "$DRY_RUN" == "true" ]]; then
    dry "  Would inject badge into gitlab:${project_path}/README.md"
    return 0
  fi

  local new_b64
  new_b64=$(echo "$new_content" | base64 -w0)
  local payload
  payload=$(jq -n \
    --arg msg "docs: add Built with Ona badge [skip ci]" \
    --arg content "$new_b64" \
    --arg branch "$ref" \
    '{commit_message:$msg, content:$content, branch:$branch, encoding:"base64"}')

  if gl_put "${GL_API}/projects/${encoded_path}/repository/files/README.md" -d "$payload" > /dev/null; then
    info "  ✅ Badge injected: gitlab:${project_path}"
  else
    warn "  ❌ Failed: gitlab:${project_path}"
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────

# shellcheck disable=SC2034
injected=0
# shellcheck disable=SC2034
skipped=0
# shellcheck disable=SC2034
failed=0

echo "========================================"
echo "  Badge Injector"
echo "  Orgs: ${ORGS}"
[[ "$DRY_RUN" == "true" ]] && echo "  (dry run)"
echo "========================================"

# GitHub pass
for org in $ORGS; do
    budget_check "${org}" || break
  info "Scanning GitHub org: ${org}..."
  mapfile -t repos < <(list_gh_repos "$org")
  info "  Found ${#repos[@]} repos."
  for repo in "${repos[@]}"; do
    process_gh_repo "$org" "$repo"
  done
done

# GitLab pass
if [[ "$SKIP_GITLAB" != "true" ]]; then
  if [[ -z "$GITLAB_TOKEN" ]]; then
    warn "GITLAB_TOKEN not set — skipping GitLab pass."
  else
    info "Scanning GitLab group: ${GITLAB_GROUP} (including subgroups)..."
    mapfile -t gl_projects < <(list_gl_projects "$GITLAB_GROUP")
    info "  Found ${#gl_projects[@]} projects."
    for project in "${gl_projects[@]}"; do
      process_gl_project "$project"
    done
  fi
fi

echo ""
budget_report
info "Done."
