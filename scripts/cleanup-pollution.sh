#!/usr/bin/env bash
#
# Removes files that were incorrectly propagated from fork-sync-all to consumer
# repos via the template sync pipeline. Only deletes files that were not present
# in the repo before the first template-sync commit (pre-template baseline).
#
# Covers: Interested-Deving-1896, OpenOS-Project-OSP, OpenOS-Project-Ecosystem-OOC,
#         and GitLab (gitlab.com/openos-project subgroups).
#
# Requires:
#   SYNC_TOKEN      — GitHub PAT with repo scope on all three GitHub orgs
#   GITLAB_TOKEN    — GitLab PAT with api + write_repository on openos-project
#
# Usage:
#   DRY_RUN=true  bash scripts/cleanup-pollution.sh   # report only
#   DRY_RUN=false bash scripts/cleanup-pollution.sh   # delete files
#
set -uo pipefail

: "${SYNC_TOKEN:?SYNC_TOKEN is required}"
: "${GITLAB_TOKEN:?GITLAB_TOKEN is required}"

DRY_RUN="${DRY_RUN:-true}"
COMMIT_MSG="chore: remove template pollution [skip ci]"

GH_API="https://api.github.com"
GL_API="https://gitlab.com/api/v4"
GH_AUTH=(-H "Authorization: token ${SYNC_TOKEN}" -H "Accept: application/vnd.github+json")
GL_AUTH=(-H "PRIVATE-TOKEN: ${GITLAB_TOKEN}")

deleted_total=0
skipped_total=0
failed_total=0

# ── Pollution file list ───────────────────────────────────────────────────────
# Every file that should never exist in a consumer repo.
ALL_POLLUTION_PATHS=(
  ".github/ISSUE_TEMPLATE/bug-report.yml"
  ".github/PULL_REQUEST_TEMPLATE.md"
  ".github/ISSUE_TEMPLATE/new-distro-support.yml"
  ".gitlab-ci.yml"
  ".gitlab/merge_request_templates/Default.md"
  ".gitlab/scheduled-maintenance.yml"
  ".devcontainer/devcontainer.json"
  ".devcontainer/features/git-filter-repo/devcontainer-feature.json"
  ".devcontainer/features/git-filter-repo/install.sh"
  ".devcontainer/features/glab/devcontainer-feature.json"
  ".devcontainer/features/glab/install.sh"
  "config/workflow-cost-profiles.yml"
  "config/workflow-sync.yml"
  "tests/conftest.py"
  "tests/test_validate_cost_profiles.py"
  "tests/test_validate_template_config.py"
  "tests/test_validate_workflow_guards.py"
  "tests/test_validate_registered_imports.py"
  "tests/test_generate_gitlab_stubs.py"
  "scripts/validate-cost-profiles.py"
  "scripts/validate-registered-imports.py"
  "scripts/validate-template-config.py"
  "scripts/validate-workflow-guards.py"
  "scripts/validate-workflows.sh"
  "scripts/generate-dep-graph.sh"
  "scripts/generate-gitlab-stubs.py"
  "scripts/init-kde-groups-mirror.py"
  "scripts/kde-path-to-gl-id.json"
  "scripts/rl-manifest-to-md.py"
  ".github/workflows/sync-template.yml"
  ".github/workflows/validate-config.yml"
  ".github/workflows/generate-dep-graph.yml"
  "config/gitlab-subgroups.yml"
  "config/template-consumers.yml"
  "config/template-manifest.yml"
  "scripts/validate-gitlab-subgroups.py"
  "scripts/sync-template.sh"
)

# ── Per-repo keep lists ───────────────────────────────────────────────────────
# Files that existed in the repo BEFORE the first template-sync commit.
# These must not be deleted even though they appear in ALL_POLLUTION_PATHS.
# Determined by baseline analysis against pre-template commit SHAs.
keep_list_for() {
  local repo="$1"
  case "$repo" in
    penguins-incus-platform|incusbox|kapsule-incus-manager)
      echo ".devcontainer/devcontainer.json" ;;
    qt-kde-team.pages.debian.net)
      echo ".gitlab-ci.yml" ;;
    *)
      echo "" ;;
  esac
}

should_keep() {
  local repo="$1" path="$2"
  local keep
  keep=$(keep_list_for "$repo")
  [[ -z "$keep" ]] && return 1
  echo "$keep" | grep -qF "$path"
}

# ── GitHub helpers ────────────────────────────────────────────────────────────

gh_get_file_sha() {
  local org="$1" repo="$2" path="$3"
  curl --disable --silent "${GH_AUTH[@]}" \
    "${GH_API}/repos/${org}/${repo}/contents/${path}" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('sha',''))" 2>/dev/null
}

gh_delete_file() {
  local org="$1" repo="$2" path="$3" sha="$4"
  local body
  body=$(python3 -c "
import json,sys
print(json.dumps({'message': sys.argv[1], 'sha': sys.argv[2]}))" \
    "$COMMIT_MSG" "$sha")
  local status
  status=$(curl --disable --silent -o /dev/null -w "%{http_code}" \
    -X DELETE "${GH_AUTH[@]}" -H "Content-Type: application/json" \
    --data "$body" \
    "${GH_API}/repos/${org}/${repo}/contents/${path}")
  echo "$status"
}

gh_cleanup_repo() {
  local org="$1" repo="$2"
  local deleted=0 skipped=0 failed=0

  echo "  ${org}/${repo}"
  for path in "${ALL_POLLUTION_PATHS[@]}"; do
    if should_keep "$repo" "$path"; then
      echo "    KEEP (pre-template): ${path}"
      (( skipped++ )) || true
      continue
    fi

    local sha
    sha=$(gh_get_file_sha "$org" "$repo" "$path")
    if [[ -z "$sha" ]]; then
      # File doesn't exist — nothing to do
      continue
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
      echo "    [dry-run] would delete: ${path}"
      (( deleted++ )) || true
      continue
    fi

    local status
    status=$(gh_delete_file "$org" "$repo" "$path" "$sha")
    if [[ "$status" == "200" ]]; then
      echo "    deleted: ${path}"
      (( deleted++ )) || true
    else
      echo "    FAILED (HTTP ${status}): ${path}" >&2
      (( failed++ )) || true
    fi
    # Avoid secondary rate limit
    sleep 0.3
  done

  [[ $deleted -gt 0 || $skipped -gt 0 || $failed -gt 0 ]] && \
    echo "    → deleted=${deleted} kept=${skipped} failed=${failed}"
  deleted_total=$(( deleted_total + deleted ))
  skipped_total=$(( skipped_total + skipped ))
  failed_total=$(( failed_total + failed ))
}

# ── GitLab helpers ────────────────────────────────────────────────────────────

gl_get_file_sha() {
  local project_id="$1" path="$2"
  local encoded_path
  encoded_path=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "$path")
  curl --disable --silent "${GL_AUTH[@]}" \
    "${GL_API}/projects/${project_id}/repository/files/${encoded_path}?ref=main" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('blob_id',''))" 2>/dev/null
}

gl_delete_file() {
  local project_id="$1" path="$2"
  local encoded_path
  encoded_path=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "$path")
  local body
  body=$(python3 -c "
import json,sys
print(json.dumps({'branch':'main','commit_message':sys.argv[1]}))" "$COMMIT_MSG")
  local status
  status=$(curl --disable --silent -o /dev/null -w "%{http_code}" \
    -X DELETE "${GL_AUTH[@]}" -H "Content-Type: application/json" \
    --data "$body" \
    "${GL_API}/projects/${project_id}/repository/files/${encoded_path}")
  echo "$status"
}

gl_cleanup_repo() {
  local project_id="$1" repo_name="$2"
  local deleted=0 skipped=0 failed=0

  echo "  gitlab: ${repo_name} (id=${project_id})"
  for path in "${ALL_POLLUTION_PATHS[@]}"; do
    if should_keep "$repo_name" "$path"; then
      echo "    KEEP (pre-template): ${path}"
      (( skipped++ )) || true
      continue
    fi

    local sha
    sha=$(gl_get_file_sha "$project_id" "$path")
    if [[ -z "$sha" ]]; then
      continue
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
      echo "    [dry-run] would delete: ${path}"
      (( deleted++ )) || true
      continue
    fi

    local status
    status=$(gl_delete_file "$project_id" "$path")
    if [[ "$status" == "204" ]]; then
      echo "    deleted: ${path}"
      (( deleted++ )) || true
    else
      echo "    FAILED (HTTP ${status}): ${path}" >&2
      (( failed++ )) || true
    fi
    sleep 0.3
  done

  [[ $deleted -gt 0 || $skipped -gt 0 || $failed -gt 0 ]] && \
    echo "    → deleted=${deleted} kept=${skipped} failed=${failed}"
  deleted_total=$(( deleted_total + deleted ))
  skipped_total=$(( skipped_total + skipped ))
  failed_total=$(( failed_total + failed ))
}

# ── Repo lists ────────────────────────────────────────────────────────────────

# GitHub: all consumer repos (script checks existence before attempting deletes)
GH_CONSUMERS=(
  "btrfs-dwarfs-framework" "eggs-ai" "eggs-gui" "immutable-linux-framework"
  "kport" "liquorix-unified-kernel" "liqxanmod" "lkf" "lkm" "oa-tools"
  "penguins-eggs" "penguins-eggs-audit" "penguins-eggs-book"
  "penguins-incus-platform" "penguins-kernel-manager" "penguins-powerwash"
  "penguins-recovery" "ukm" "xanmod-unified-kernel"
  "Incus-MacOS-Toolkit" "incus-image-server" "incus-windows-toolkit"
  "incusbox" "kapsule-incus-manager" "talos" "talos-incus" "waydroid-toolkit"
  "gitlab-enhanced" "linux-powerwash" "penguins-immutable-framework"
  "docker-images" "pkg-kde-dev-scripts" "pkg-kde-jenkins" "pkg-kde-tools"
  "qt-kde-team.pages.debian.net" "ubuntu-core"
  "matrix-lock" "github-actions-virtualization-support"
  "niko-claude-skills" "actions-orchestrator" "build-server"
)

# GitLab: project IDs from config/gitlab-subgroups.yml
# (fork-sync-all itself is in the ops subgroup, id 130734009)
GL_REPOS=(
  "130734009:fork-sync-all"
  "130516820:gitlab-enhanced"
  "130516402:penguins-eggs"
  "130516402:penguins-recovery"
  "130516402:penguins-eggs-book"
  "130516402:penguins-eggs-audit"
  "130516402:penguins-powerwash"
  "130516402:penguins-incus-platform"
  "130516402:penguins-kernel-manager"
  "130516402:penguins-immutable-framework"
  "130516465:immutable-linux-framework"
  "130516188:liqxanmod"
  "130516188:lkm"
  "130516188:ukm"
  "130516188:lkf"
  "130516188:liquorix-unified-kernel"
  "130516188:xanmod-unified-kernel"
  "130516188:btrfs-dwarfs-framework"
  "130516188:linux-powerwash"
  "130516536:incus-image-server"
  "130516536:kapsule-incus-manager"
  "130516536:incusbox"
  "130516536:Incus-MacOS-Toolkit"
  "130516536:incus-windows-toolkit"
  "130516536:talos"
  "130516536:talos-incus"
  "130516536:waydroid-toolkit"
  "130739746:KPort"
  "130739746:ubuntu-core"
  "130739746:pkg-kde-tools"
  "130739746:pkg-kde-jenkins"
  "130739746:pkg-kde-dev-scripts"
  "130739746:docker-images"
  "130739746:qt-kde-team.pages.debian.net"
)

# ── Main ──────────────────────────────────────────────────────────────────────

[[ "$DRY_RUN" == "true" ]] && echo "DRY RUN — no files will be deleted" || echo "LIVE RUN — deleting files"
echo ""

echo "=== Interested-Deving-1896 ==="
for repo in "${GH_CONSUMERS[@]}"; do
  gh_cleanup_repo "Interested-Deving-1896" "$repo"
done

echo ""
echo "=== OpenOS-Project-OSP ==="
for repo in "${GH_CONSUMERS[@]}"; do
  # Check existence first
  status=$(curl --disable --silent -o /dev/null -w "%{http_code}" \
    "${GH_AUTH[@]}" "${GH_API}/repos/OpenOS-Project-OSP/${repo}")
  [[ "$status" != "200" ]] && continue
  gh_cleanup_repo "OpenOS-Project-OSP" "$repo"
done

echo ""
echo "=== OpenOS-Project-Ecosystem-OOC ==="
for repo in "${GH_CONSUMERS[@]}"; do
  status=$(curl --disable --silent -o /dev/null -w "%{http_code}" \
    "${GH_AUTH[@]}" "${GH_API}/repos/OpenOS-Project-Ecosystem-OOC/${repo}")
  [[ "$status" != "200" ]] && continue
  gh_cleanup_repo "OpenOS-Project-Ecosystem-OOC" "$repo"
done

echo ""
echo "=== GitLab (openos-project) ==="
for entry in "${GL_REPOS[@]}"; do
  project_id="${entry%%:*}"
  repo_name="${entry##*:}"
  # Resolve actual numeric project ID by searching under the subgroup
  actual_id=$(curl --disable --silent "${GL_AUTH[@]}" \
    "${GL_API}/groups/${project_id}/projects?search=${repo_name}&per_page=5" \
    | python3 -c "
import sys,json
d=json.load(sys.stdin)
matches=[p for p in d if p.get('path','').lower()=='${repo_name}'.lower() or p.get('name','').lower()=='${repo_name}'.lower()]
print(matches[0]['id'] if matches else '')
" 2>/dev/null)
  if [[ -z "$actual_id" ]]; then
    echo "  gitlab: ${repo_name} — not found in subgroup ${project_id}"
    continue
  fi
  gl_cleanup_repo "$actual_id" "$repo_name"
done

echo ""
echo "cleanup-pollution: done — deleted=${deleted_total} kept=${skipped_total} failed=${failed_total}"
[[ "$failed_total" -gt 0 ]] && exit 1
exit 0
