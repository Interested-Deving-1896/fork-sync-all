#!/usr/bin/env bash
#
# Syncs all KDE group mirror repos under
# openos-project/kde-ecosystem-deving/kde-groups from invent.kde.org.
#
# For each GitLab project in the kde-groups hierarchy, derives the upstream
# KDE Invent URL from the project path and pushes branches + tags.
# Skips refs/merge-requests/* which GitLab rejects as hidden refs.
#
# Required CI variable: GITLAB_TOKEN — PAT with api + write_repository scope
#
# This script is designed to be resumable: it processes all projects in
# alphabetical order and continues on individual failures.

set -uo pipefail

GITLAB_API="https://gitlab.com/api/v4"
KDE_BASE="https://invent.kde.org"
KDE_GROUPS_GL_ID="130743027"  # openos-project/kde-ecosystem-deving/kde-groups
# shellcheck disable=SC2034
KDE_GROUPS_GL_PATH="openos-project/kde-ecosystem-deving/kde-groups"

: "${GITLAB_TOKEN:?GITLAB_TOKEN is required}"

info()  { echo "[kde-groups] $*"; }
warn()  { echo "[kde-groups][warn] $*" >&2; }

SYNCED=0
FAILED=0
SKIPPED=0

info "Fetching all projects under kde-groups (id=${KDE_GROUPS_GL_ID})..."

# Collect all projects across all pages
projects_json=$(python3 - <<PYEOF
import urllib.request, json, sys

TOKEN = "${GITLAB_TOKEN}"
API = "${GITLAB_API}"
GROUP_ID = "${KDE_GROUPS_GL_ID}"

projects = []
page = 1
while True:
    req = urllib.request.Request(
        f"{API}/groups/{GROUP_ID}/projects?include_subgroups=true&per_page=100&page={page}&archived=false",
        headers={"PRIVATE-TOKEN": TOKEN}
    )
    with urllib.request.urlopen(req, timeout=20) as r:
        batch = json.load(r)
    if not batch:
        break
    projects.extend(batch)
    page += 1

# Emit tab-separated: gl_http_url <TAB> kde_path <TAB> default_branch
for p in sorted(projects, key=lambda x: x["path_with_namespace"]):
    # Derive KDE path by stripping the kde-groups prefix
    kde_path = p["path_with_namespace"].replace(f"{GROUP_ID}/", "")
    # Strip openos-project/kde-ecosystem-deving/kde-groups/ prefix
    full = p["path_with_namespace"]
    prefix = "openos-project/kde-ecosystem-deving/kde-groups/"
    if full.startswith(prefix):
        kde_path = full[len(prefix):]
    else:
        kde_path = p["path"]
    branch = p.get("default_branch") or "master"
    print(f"{p['http_url_to_repo']}\t{kde_path}\t{branch}")
PYEOF
)

total=$(echo "$projects_json" | wc -l)
info "Found ${total} projects to sync"

# shellcheck disable=SC2034
while IFS=$'\t' read -r gl_url kde_path default_branch; do
    [ -z "$gl_url" ] && continue

    kde_url="${KDE_BASE}/${kde_path}.git"
    gl_auth_url="${gl_url/https:\/\//https://oauth2:${GITLAB_TOKEN}@}"

    info "Syncing ${kde_path} ..."
    work_dir=$(mktemp -d)

    # Shallow clone (--depth=50): fetches only the last 50 commits per branch.
    # Cuts storage by ~95% vs a full mirror clone while keeping enough history
    # for git log to be useful. Tags are fetched separately (--no-tags on clone,
    # then explicit fetch) so tag objects don't pull in deep history chains.
    if git clone --bare --depth=50 --no-tags \
            --config remote.origin.fetch='+refs/heads/*:refs/heads/*' \
            "${kde_url}" "${work_dir}" 2>/dev/null; then
        # Fetch lightweight tags without deepening history
        git -C "${work_dir}" fetch --depth=1 --tags origin 2>/dev/null || true
        # Push branches and tags to GitLab
        if git -C "${work_dir}" push "${gl_auth_url}" \
            "+refs/heads/*:refs/heads/*" \
            "+refs/tags/*:refs/tags/*" 2>/dev/null; then
            info "  ✅ ${kde_path}"
            SYNCED=$((SYNCED + 1))
        else
            warn "  ❌ ${kde_path} — push failed"
            FAILED=$((FAILED + 1))
        fi
    else
        warn "  ❌ ${kde_path} — clone from invent.kde.org failed (repo may be empty or moved)"
        FAILED=$((FAILED + 1))
    fi

    rm -rf "${work_dir}"

done <<< "$projects_json"

echo ""
info "Done — synced=${SYNCED} | failed=${FAILED} | skipped=${SKIPPED}"
[ "${FAILED}" -eq 0 ] || exit 1
