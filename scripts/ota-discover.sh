#!/usr/bin/env bash
#
# ota-discover.sh
#
# Scans GitHub for forks of fork-sync-all that contain .ota/config.yml with
# enabled: true. Adds newly discovered repos to config/ota-registry.yml and
# opens a PR with the changes.
#
# This is the passive discovery path — repos that ran ota-opt-in but whose
# registration PR was never merged will still be found here.
#
# Triggered by ota-discover.yml on a schedule (daily).
#
# Usage:
#   GH_TOKEN=ghp_... bash scripts/ota-discover.sh
#
# Required env:
#   GH_TOKEN        GitHub PAT with repo read access
#
# Optional env:
#   REGISTRY_FILE   Path to ota-registry.yml (default: config/ota-registry.yml)
#   BLOCKLIST_FILE  Path to ota-blocklist.yml (default: config/ota-blocklist.yml)
#   SOURCE_REPO     The repo to scan forks of (default: Interested-Deving-1896/fork-sync-all)
#   DRY_RUN         "true" to skip registry updates and PR creation
#
set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"

REGISTRY_FILE="${REGISTRY_FILE:-config/ota-registry.yml}"
BLOCKLIST_FILE="${BLOCKLIST_FILE:-config/ota-blocklist.yml}"
SOURCE_REPO="${SOURCE_REPO:-Interested-Deving-1896/fork-sync-all}"
DRY_RUN="${DRY_RUN:-false}"
API="https://api.github.com"
PER_PAGE=100

found=0
added=0
skipped=0

# ── helpers ───────────────────────────────────────────────────────────────────

gh_api() {
  local method="$1" url="$2"; shift 2
  local response http_code body attempt=0 max_retries=3

  while true; do
    response=$(curl -s -w "\n%{http_code}" \
      -X "$method" \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "$@" "$url" 2>/dev/null) || true
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" == "403" || "$http_code" == "429" ]]; then
      (( attempt++ ))
      (( attempt > max_retries )) && { echo "$body"; return 1; }
      echo "  Rate limited — backing off 60s..." >&2
      sleep 60
      continue
    fi
    echo "$body"
    return 0
  done
}

log()  { echo "[discover] $*"; }
warn() { echo "[discover] WARN: $*" >&2; }

# ── read existing registry ────────────────────────────────────────────────────

mapfile -t EXISTING_REPOS < <(python3 -c "
in_opted = False
repo = ''
with open('${REGISTRY_FILE}') as f:
    for line in f:
        s = line.strip()
        if s == 'opted_in:':
            in_opted = True
        elif in_opted and s.startswith('- repo:'):
            repo = s.split(':', 1)[1].strip().strip('\"')
            print(repo)
" 2>/dev/null || true)

log "Existing registry entries: ${#EXISTING_REPOS[@]}"

# ── read blocklist ────────────────────────────────────────────────────────────

mapfile -t BLOCKED_ORGS < <(python3 -c "
in_orgs = False
with open('${BLOCKLIST_FILE}') as f:
    for line in f:
        s = line.strip()
        if s == 'github_orgs:':
            in_orgs = True
        elif s and not s.startswith('- ') and in_orgs:
            in_orgs = False
        elif in_orgs and s.startswith('- '):
            print(s[2:].strip().lower())
" 2>/dev/null || true)

# ── scan forks ────────────────────────────────────────────────────────────────

log "Scanning forks of ${SOURCE_REPO} for .ota/config.yml..."

# Fetch fork list via GraphQL (1 call) instead of paginated REST.
# Falls back to REST if GraphQL returns nothing.
_source_owner="${SOURCE_REPO%%/*}"
_source_name="${SOURCE_REPO##*/}"

_fork_list=""
_gql_cursor=""
while true; do
  _after_arg=""
  [[ -n "$_gql_cursor" ]] && _after_arg=", after: \\\"${_gql_cursor}\\\""
  _gql_result=$(curl -sf \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Content-Type: application/json" \
    "${API}/graphql" \
    -d "{\"query\":\"{ repository(owner: \\\"${_source_owner}\\\", name: \\\"${_source_name}\\\") { forks(first: 100${_after_arg}, orderBy: {field: CREATED_AT, direction: DESC}) { nodes { nameWithOwner } pageInfo { hasNextPage endCursor } } } }\"}" \
    2>/dev/null || echo "{}")
  _page_forks=$(echo "$_gql_result" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for n in d.get('data',{}).get('repository',{}).get('forks',{}).get('nodes',[]):
    print(n['nameWithOwner'])
" 2>/dev/null || true)
  _fork_list+="${_page_forks}"$'\n'
  _has_next=$(echo "$_gql_result" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('true' if d.get('data',{}).get('repository',{}).get('forks',{}).get('pageInfo',{}).get('hasNextPage') else 'false')
" 2>/dev/null || echo "false")
  [[ "$_has_next" != "true" ]] && break
  _gql_cursor=$(echo "$_gql_result" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d.get('data',{}).get('repository',{}).get('forks',{}).get('pageInfo',{}).get('endCursor',''))
" 2>/dev/null || echo "")
  [[ -z "$_gql_cursor" ]] && break
done

# Fallback to REST if GraphQL returned nothing
if [[ -z "$(echo "$_fork_list" | grep -v '^$')" ]]; then
  log "GraphQL fork list empty — falling back to REST"
  page=1
  while true; do
    result=$(gh_api GET "${API}/repos/${SOURCE_REPO}/forks?per_page=${PER_PAGE}&page=${page}&sort=newest") || break
    count=$(echo "$result" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
    [[ "$count" == "0" ]] && break
    _fork_list+=$(echo "$result" | python3 -c "
import sys,json
for r in json.load(sys.stdin): print(r['full_name'])
" 2>/dev/null || true)
    _fork_list+=$'\n'
    (( page++ ))
  done
fi

NEW_REPOS=()

while IFS= read -r fork_repo; do
    [[ -z "$fork_repo" ]] && continue
    (( found++ ))

    fork_org="${fork_repo%%/*}"

    # Skip blocklisted orgs
    blocked=false
    for blocked_org in "${BLOCKED_ORGS[@]}"; do
      [[ "${fork_org,,}" == "$blocked_org" ]] && blocked=true && break
    done
    if [[ "$blocked" == "true" ]]; then
      (( skipped++ ))
      continue
    fi

    # Skip already registered
    already=false
    for existing in "${EXISTING_REPOS[@]}"; do
      [[ "$existing" == "$fork_repo" ]] && already=true && break
    done
    if [[ "$already" == "true" ]]; then
      (( skipped++ ))
      continue
    fi

    # Check for .ota/config.yml with enabled: true
    config_response=$(gh_api GET "${API}/repos/${fork_repo}/contents/.ota/config.yml" 2>/dev/null || true)
    config_content=$(echo "$config_response" | python3 -c "
import sys, json, base64
try:
    d = json.load(sys.stdin)
    if 'content' in d:
        print(base64.b64decode(d['content']).decode())
except:
    pass
" 2>/dev/null || true)

    if [[ -z "$config_content" ]]; then
      (( skipped++ ))
      continue
    fi

    # Check enabled: true
    if ! echo "$config_content" | grep -q "^enabled: true"; then
      log "  ${fork_repo}: .ota/config.yml found but enabled: false — skipping"
      (( skipped++ ))
      continue
    fi

    # Check mirror_chain_opt_in for non-standalone repos
    mirror_opt_in=$(echo "$config_content" | grep "mirror_chain_opt_in:" | awk '{print $2}' || true)

    log "  ${fork_repo}: opted in — adding to registry"
    NEW_REPOS+=("$fork_repo")

done < <(echo "$_fork_list" | grep -v '^$')

log "Scan complete: ${found} forks found, ${#NEW_REPOS[@]} new opt-ins, ${skipped} skipped"

if [[ "${#NEW_REPOS[@]}" -eq 0 ]]; then
  log "No new opt-ins found — registry is up to date"
  exit 0
fi

if [[ "$DRY_RUN" == "true" ]]; then
  log "DRY: would add ${#NEW_REPOS[@]} repos to registry:"
  for r in "${NEW_REPOS[@]}"; do log "  - ${r}"; done
  exit 0
fi

# ── update registry ───────────────────────────────────────────────────────────

TODAY=$(date -u +%Y-%m-%d)

# Build YAML entries for new repos
NEW_ENTRIES=""
for repo in "${NEW_REPOS[@]}"; do
  NEW_ENTRIES+="  - repo: \"${repo}\"
    host: github
    registered_at: \"${TODAY}\"
    pinned_sha: \"\"
    discovery: true
    mirror_chain_opt_in: false
    disabled: false
"
  (( added++ ))
done

# Append to registry — replace the trailing comment block with entries + comment
python3 - "$REGISTRY_FILE" "$NEW_ENTRIES" <<'PYEOF'
import sys

registry_file = sys.argv[1]
new_entries = sys.argv[2]

with open(registry_file) as f:
    content = f.read()

# Find the opted_in: key and append after it (or after existing entries)
if 'opted_in: []' in content:
    content = content.replace('opted_in: []', 'opted_in:\n' + new_entries.rstrip())
elif 'opted_in:' in content:
    # Append before the trailing comment block
    lines = content.splitlines()
    insert_at = len(lines)
    for i in range(len(lines) - 1, -1, -1):
        if lines[i].strip().startswith('- repo:') or lines[i].strip() == 'opted_in:':
            insert_at = i + 1
            # Walk forward past the full entry block
            while insert_at < len(lines) and (lines[insert_at].startswith('  ') or lines[insert_at].strip() == ''):
                insert_at += 1
            break
    lines.insert(insert_at, new_entries.rstrip())
    content = '\n'.join(lines) + '\n'

with open(registry_file, 'w') as f:
    f.write(content)

print(f"Registry updated")
PYEOF

log "Registry updated with ${added} new entries"

# ── open PR ───────────────────────────────────────────────────────────────────

BRANCH="ota/discover-$(date -u +%Y%m%d)"
git checkout -b "$BRANCH" 2>/dev/null || git checkout "$BRANCH" 2>/dev/null
git add "$REGISTRY_FILE"

if git diff --cached --quiet; then
  log "No staged changes — nothing to PR"
  exit 0
fi

git -c user.name="ota-bot" -c user.email="ota@fork-sync-all" \
  commit -m "chore: OTA discovery — add ${added} new opt-in(s)

Discovered via scheduled scan of forks with .ota/config.yml.

Co-authored-by: Ona <no-reply@ona.com>" 2>/dev/null

git push --quiet origin "$BRANCH" 2>/dev/null

# Open PR via API
pr_body="## OTA Discovery — ${added} new opt-in(s)

The scheduled OTA discovery scan found the following repos with \`.ota/config.yml\` set to \`enabled: true\`:

$(for r in "${NEW_REPOS[@]}"; do echo "- \`${r}\`"; done)

Merging this PR adds them to the OTA delivery registry. They will receive OTA updates on the next release."

gh_api POST "${API}/repos/${SOURCE_REPO}/pulls" \
  -H "Content-Type: application/json" \
  -d "$(python3 -c "
import json, sys
print(json.dumps({
  'title': 'chore: OTA discovery — add ${added} new opt-in(s)',
  'head': '${BRANCH}',
  'base': 'main',
  'body': sys.stdin.read()
}))
" <<< "$pr_body")" >/dev/null

log "Discovery PR opened for ${added} new opt-in(s)"
exit 0
