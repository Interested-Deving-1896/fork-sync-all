#!/usr/bin/env bash
#
# Removes files that were incorrectly propagated from fork-sync-all to consumer
# repos via the template sync pipeline. Only deletes files that were not present
# in the repo before the first template-sync commit (pre-template baseline).
#
# Covers: Interested-Deving-1896, OpenOS-Project-OSP, OpenOS-Project-Ecosystem-OOC,
#         and GitLab (gitlab.com/openos-project subgroups).
#
# Efficiency: fetches each repo's full git tree in one API call, then issues
# DELETE requests only for files that actually exist. This keeps total API
# usage to ~2 calls per repo (tree fetch + N deletes) rather than one probe
# per pollution path per repo.
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
# GITLAB_TOKEN is optional — if unset, the GitLab cleanup section is skipped.
GITLAB_TOKEN="${GITLAB_TOKEN:-}"

DRY_RUN="${DRY_RUN:-true}"
COMMIT_MSG="chore: remove template pollution [skip ci]"

GH_API="https://api.github.com"
GL_API="https://gitlab.com/api/v4"
GH_AUTH=(-H "Authorization: token ${SYNC_TOKEN}" -H "Accept: application/vnd.github+json")
GL_AUTH=(-H "PRIVATE-TOKEN: ${GITLAB_TOKEN}")


# ── Budget guard ─────────────────────────────────────────────────────────────
source "$(dirname "${BASH_SOURCE[0]}")/includes/budget.sh"
budget_init

deleted_total=0
skipped_total=0
failed_total=0

# ── Pollution file list ───────────────────────────────────────────────────────
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
  # Org-wide workflows incorrectly propagated to consumer repos — these run
  # centrally from fork-sync-all and must not exist on consumer repos.
  ".github/workflows/notify-poller.yml"
  ".github/workflows/resolve-failures.yml"
  ".github/workflows/translate-readmes.yml"
  ".github/workflows/update-infra-deps.yml"
  ".github/workflows/cleanup-branches.yml"
  # Scripts that only make sense on fork-sync-all
  "scripts/cleanup-branches.sh"
  "scripts/resolve-failures.sh"
  "scripts/update-infra-deps.sh"
  "scripts/translate-readmes.sh"
  "config/gitlab-subgroups.yml"
  "config/template-consumers.yml"
  "config/template-manifest.yml"
  "scripts/validate-gitlab-subgroups.py"
  "scripts/sync-template.sh"
)

# ── Per-repo keep lists ───────────────────────────────────────────────────────
# Files confirmed to have existed before the first template-sync commit.
keep_list_for() {
  case "$1" in
    penguins-incus-platform|incusbox|kapsule-incus-manager)
      echo ".devcontainer/devcontainer.json" ;;
    qt-kde-team.pages.debian.net)
      echo ".gitlab-ci.yml" ;;
    *) echo "" ;;
  esac
}

should_keep() {
  local keep
  keep=$(keep_list_for "$1")
  [[ -z "$keep" ]] && return 1
  echo "$keep" | grep -qF "$2"
}

# ── GitHub cleanup ────────────────────────────────────────────────────────────
# One tree fetch per repo, then delete only present pollution files.

gh_cleanup_repo() {
  local org="$1" repo="$2"
  local deleted=0 skipped=0 failed=0

  # Single API call: full recursive tree with blob SHAs
  local tree_json
  tree_json=$(curl --disable --silent "${GH_AUTH[@]}" \
    "${GH_API}/repos/${org}/${repo}/git/trees/HEAD?recursive=1" 2>/dev/null)

  local msg
  msg=$(echo "$tree_json" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d.get('message',''))" 2>/dev/null)
  if [[ -n "$msg" ]]; then
    echo "  SKIP ${org}/${repo}: ${msg}" >&2
    return
  fi

  # Intersect tree with pollution list — emit path<TAB>sha for matches
  local present
  present=$(echo "$tree_json" | python3 -c "
import sys, json
tree = json.load(sys.stdin).get('tree', [])
by_path = {item['path']: item['sha'] for item in tree if item['type'] == 'blob'}
pollution = set($(printf '"%s"\n' "${ALL_POLLUTION_PATHS[@]}" | \
  python3 -c "import sys; lines=[l.strip().strip('\"') for l in sys.stdin if l.strip()]; print('[' + ','.join(repr(l) for l in lines) + ']')"))
for p in sorted(pollution):
    if p in by_path:
        print(p + '\t' + by_path[p])
" 2>/dev/null)

  [[ -z "$present" ]] && return

  local hit_count
  hit_count=$(echo "$present" | wc -l | tr -d ' ')
  echo "  ${org}/${repo} (${hit_count} files to remove)"

  while IFS=$'\t' read -r path sha; do
    [[ -z "$path" ]] && continue

    if should_keep "$repo" "$path"; then
      echo "    KEEP (pre-template): ${path}"
      (( skipped++ )) || true
      continue
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
      echo "    [dry-run] would delete: ${path}"
      (( deleted++ )) || true
      continue
    fi

    local body status
    body=$(python3 -c "import json,sys
print(json.dumps({'message':sys.argv[1],'sha':sys.argv[2]}))" \
      "$COMMIT_MSG" "$sha")
    status=$(curl --disable --silent -o /dev/null -w "%{http_code}" \
      -X DELETE "${GH_AUTH[@]}" -H "Content-Type: application/json" \
      --data "$body" \
      "${GH_API}/repos/${org}/${repo}/contents/${path}")

    if [[ "$status" == "200" ]]; then
      echo "    deleted: ${path}"
      (( deleted++ )) || true
    elif [[ "$status" == "404" ]]; then
      echo "    already gone: ${path}"
    else
      echo "    FAILED (HTTP ${status}): ${path}" >&2
      (( failed++ )) || true
    fi
    sleep 0.15
  done <<< "$present"

  [[ $deleted -gt 0 || $skipped -gt 0 || $failed -gt 0 ]] && \
    echo "    → deleted=${deleted} kept=${skipped} failed=${failed}"
  deleted_total=$(( deleted_total + deleted ))
  skipped_total=$(( skipped_total + skipped ))
  failed_total=$(( failed_total + failed ))
}

# ── GitLab cleanup ────────────────────────────────────────────────────────────

gl_cleanup_repo() {
  local project_id="$1" repo_name="$2"
  local deleted=0 skipped=0 failed=0

  # GitLab tree API paginates at 100 items — fetch all pages
  local tree_json="[]" page=1 page_json
  while true; do
    page_json=$(curl --disable --silent "${GL_AUTH[@]}" \
      "${GL_API}/projects/${project_id}/repository/tree?recursive=true&per_page=100&page=${page}&ref=main" 2>/dev/null)
    local count
    count=$(echo "$page_json" | python3 -c \
      "import sys,json; d=json.load(sys.stdin); print(len(d) if isinstance(d,list) else 0)" 2>/dev/null)
    [[ "$count" -eq 0 ]] && break
    tree_json=$(python3 -c "
import sys,json
a=json.loads(sys.argv[1]); b=json.loads(sys.argv[2]); print(json.dumps(a+b))
" "$tree_json" "$page_json" 2>/dev/null)
    [[ "$count" -lt 100 ]] && break
    (( page++ )) || true
  done

  local present
  present=$(echo "$tree_json" | python3 -c "
import sys, json
tree = json.load(sys.stdin)
if not isinstance(tree, list): sys.exit(0)
paths = {item['path'] for item in tree if item['type'] == 'blob'}
pollution = set($(printf '"%s"\n' "${ALL_POLLUTION_PATHS[@]}" | \
  python3 -c "import sys; lines=[l.strip().strip('\"') for l in sys.stdin if l.strip()]; print('[' + ','.join(repr(l) for l in lines) + ']')"))
for p in sorted(pollution):
    if p in paths:
        print(p)
" 2>/dev/null)

  [[ -z "$present" ]] && return

  local hit_count
  hit_count=$(echo "$present" | wc -l | tr -d ' ')
  echo "  gitlab: ${repo_name} (${hit_count} files to remove)"

  while IFS= read -r path; do
    [[ -z "$path" ]] && continue

    if should_keep "$repo_name" "$path"; then
      echo "    KEEP (pre-template): ${path}"
      (( skipped++ )) || true
      continue
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
      echo "    [dry-run] would delete: ${path}"
      (( deleted++ )) || true
      continue
    fi

    local encoded body status
    encoded=$(python3 -c \
      "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "$path")
    body=$(python3 -c "import json,sys
print(json.dumps({'branch':'main','commit_message':sys.argv[1]}))" "$COMMIT_MSG")
    status=$(curl --disable --silent -o /dev/null -w "%{http_code}" \
      -X DELETE "${GL_AUTH[@]}" -H "Content-Type: application/json" \
      --data "$body" \
      "${GL_API}/projects/${project_id}/repository/files/${encoded}")

    if [[ "$status" == "204" ]]; then
      echo "    deleted: ${path}"
      (( deleted++ )) || true
    elif [[ "$status" == "404" ]]; then
      echo "    already gone: ${path}"
    else
      echo "    FAILED (HTTP ${status}): ${path}" >&2
      (( failed++ )) || true
    fi
    sleep 0.15
  done <<< "$present"

  [[ $deleted -gt 0 || $skipped -gt 0 || $failed -gt 0 ]] && \
    echo "    → deleted=${deleted} kept=${skipped} failed=${failed}"
  deleted_total=$(( deleted_total + deleted ))
  skipped_total=$(( skipped_total + skipped ))
  failed_total=$(( failed_total + failed ))
}

# ── Repo lists ────────────────────────────────────────────────────────────────

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

[[ "$DRY_RUN" == "true" ]] && echo "DRY RUN — no files will be deleted" \
  || echo "LIVE RUN — deleting files"
echo ""

echo "=== Interested-Deving-1896 ==="
for repo in "${GH_CONSUMERS[@]}"; do
    budget_check "${repo}" || break
  gh_cleanup_repo "Interested-Deving-1896" "$repo"
done

echo ""
echo "=== OpenOS-Project-OSP ==="
for repo in "${GH_CONSUMERS[@]}"; do
  gh_cleanup_repo "OpenOS-Project-OSP" "$repo"
done

echo ""
echo "=== OpenOS-Project-Ecosystem-OOC ==="
for repo in "${GH_CONSUMERS[@]}"; do
  gh_cleanup_repo "OpenOS-Project-Ecosystem-OOC" "$repo"
done

echo ""
echo "=== GitLab (openos-project) ==="
if [[ -z "$GITLAB_TOKEN" ]]; then
  echo "  GITLAB_TOKEN not set — skipping GitLab cleanup."
else
  for entry in "${GL_REPOS[@]}"; do
    subgroup_id="${entry%%:*}"
    repo_name="${entry##*:}"
    actual_id=$(curl --disable --silent "${GL_AUTH[@]}" \
      "${GL_API}/groups/${subgroup_id}/projects?search=${repo_name}&per_page=5" \
      | python3 -c "
import sys,json
d=json.load(sys.stdin)
if not isinstance(d,list): sys.exit(0)
matches=[p for p in d if p.get('path','').lower()=='${repo_name}'.lower()]
print(matches[0]['id'] if matches else '')
" 2>/dev/null)
    if [[ -z "$actual_id" ]]; then
      echo "  gitlab: ${repo_name} — not found in subgroup ${subgroup_id}"
      continue
    fi
    gl_cleanup_repo "$actual_id" "$repo_name"
  done
fi

echo ""
echo "cleanup-pollution: done — deleted=${deleted_total} kept=${skipped_total} failed=${failed_total}"
[[ "$failed_total" -gt 0 ]] && exit 1
budget_report
exit 0
