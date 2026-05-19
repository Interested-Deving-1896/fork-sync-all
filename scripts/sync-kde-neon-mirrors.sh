#!/usr/bin/env bash
#
# Syncs all KDE Neon mirror repos in openos-project/kde-ecosystem-deving/neon-deving
# from their upstream sources at https://invent.kde.org/neon/.
#
# Required CI variable: GITLAB_TOKEN — PAT with api + write_repository scope

set -euo pipefail

GITLAB_API="https://gitlab.com/api/v4"
NEON_GROUP_ID="130739746"  # openos-project/kde-ecosystem-deving/neon-deving
KDE_BASE="https://invent.kde.org/neon"

info()  { echo "[kde-neon] $*"; }
warn()  { echo "[kde-neon][warn] $*" >&2; }

: "${GITLAB_TOKEN:?GITLAB_TOKEN is required}"

# Fetch all projects in the neon-deving group
info "Fetching project list from neon-deving (id=${NEON_GROUP_ID})..."
projects=$(curl -sf \
  --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "${GITLAB_API}/groups/${NEON_GROUP_ID}/projects?per_page=100&include_subgroups=false")

total=$(echo "$projects" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
info "Found ${total} projects"

SYNCED=0
FAILED=0
SKIPPED=0

# shellcheck disable=SC2034
while IFS=$'\t' read -r pid name gl_url; do
  kde_url="${KDE_BASE}/${name}.git"
  gl_auth_url="${gl_url/https:\/\//https://oauth2:${GITLAB_TOKEN}@}"

  info "Syncing ${name} ← ${kde_url} ..."
  work_dir=$(mktemp -d)

  if git clone --mirror "${kde_url}" "${work_dir}" 2>&1 | tail -1; then
    if git -C "${work_dir}" push --mirror "${gl_auth_url}" 2>&1 | tail -3; then
      info "  ✅ ${name} synced"
      SYNCED=$((SYNCED + 1))
    else
      warn "  ❌ ${name} push to GitLab failed"
      FAILED=$((FAILED + 1))
    fi
  else
    warn "  ❌ ${name} clone from invent.kde.org failed"
    FAILED=$((FAILED + 1))
  fi

  rm -rf "${work_dir}"

done < <(echo "$projects" | python3 -c "
import sys, json
for p in json.load(sys.stdin):
    print(p['id'], p['name'], p['http_url_to_repo'], sep='\t')
")

echo ""
info "Done — synced=${SYNCED} | failed=${FAILED} | skipped=${SKIPPED}"
[ "${FAILED}" -eq 0 ] || exit 1
