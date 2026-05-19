#!/bin/bash
# scripts/sync-upstream-mirrors.sh
#
# Syncs all upstream mirror repos in openos-project/upstream-mirrors from
# their original GitHub sources. Runs as a scheduled GitLab CI job.
#
# Required CI variable: GITLAB_TOKEN (masked) — GitLab PAT with api + write_repository scope

set -euo pipefail

GITLAB_API="https://gitlab.com/api/v4"
MIRROR_GROUP="openos-project/upstream-mirrors"
MIRROR_GROUP_ENCODED="openos-project%2Fupstream-mirrors"

info()  { echo "[sync] $*"; }
warn()  { echo "[warn] $*" >&2; }
error() { echo "[error] $*" >&2; }

# Fetch all projects in the upstream-mirrors group
info "Fetching project list from ${MIRROR_GROUP}..."
projects=$(curl -sf \
  --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "${GITLAB_API}/groups/${MIRROR_GROUP_ENCODED}/projects?per_page=100&include_subgroups=false")

total=$(echo "$projects" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
info "Found ${total} mirror projects"

SYNCED=0
SKIPPED=0
FAILED=0

# Process each project
echo "$projects" | python3 -c "
import sys, json
for p in json.load(sys.stdin):
    src = p.get('import_url') or ''
    # Skip projects with no GitHub source (manually pushed, e.g. buildroot, linux-xanmod)
    if not src.startswith('https://github.com'):
        src = ''
    print(p['id'], p['name'], p['http_url_to_repo'], src)
" | while read -r _pid name gl_url gh_url; do

  if [ -z "$gh_url" ]; then
    info "SKIP (no GitHub source): ${name}"
    continue
  fi

  info "Syncing ${name} ..."
  work_dir=$(mktemp -d)

  # Inject token into GitLab URL
  gl_auth_url="${gl_url/https:\/\//https://oauth2:${GITLAB_TOKEN}@}"

  if git clone --mirror "$gh_url" "$work_dir" 2>/dev/null; then
    cd "$work_dir"
    if git push --mirror "$gl_auth_url" 2>/dev/null; then
      info "  ✅ ${name} synced"
      SYNCED=$((SYNCED + 1))
    else
      warn "  ❌ ${name} push failed"
      FAILED=$((FAILED + 1))
    fi
    cd /
  else
    warn "  ❌ ${name} clone from GitHub failed"
    FAILED=$((FAILED + 1))
  fi

  rm -rf "$work_dir"
done

echo ""
info "Done — synced: ${SYNCED} | skipped: ${SKIPPED} | failed: ${FAILED}"
