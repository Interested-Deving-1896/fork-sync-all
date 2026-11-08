#!/usr/bin/env bash
#
# Removes files that were incorrectly propagated from fork-sync-all to consumer
# repos via the template sync pipeline. Only deletes files that were not present
# in the repo before the first template-sync commit (pre-template baseline).
#
# Targets come only from enabled, managed entries in config/template-consumers.yml.
# Bare names use Interested-Deving-1896; qualified names preserve their owner.
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
#   DRY_RUN=true bash scripts/cleanup-pollution.sh    # report only
#
# Live deletion is intentionally disabled until per-repository template
# ownership can be proven from verified history. DRY_RUN=false fails closed.
#
set -uo pipefail

DRY_RUN="${DRY_RUN:-true}"
if [[ "$DRY_RUN" != "true" ]]; then
  echo "ERROR: live cleanup is disabled; verified per-repository ownership evidence is not implemented." >&2
  echo "Run with DRY_RUN=true to produce a non-destructive report." >&2
  exit 2
fi

: "${SYNC_TOKEN:?SYNC_TOKEN is required}"
GH_API="https://api.github.com"
GH_AUTH=(-H "Authorization: token ${SYNC_TOKEN}" -H "Accept: application/vnd.github+json")


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
# Legacy manual keep hints only; these are not historical ownership evidence.
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
      echo "    KEEP (legacy manual exception; not ownership evidence): ${path}"
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

# ── Registry-derived target routing ──────────────────────────────────────────

REGISTRY_FILE="${CONSUMERS_FILE:-$(dirname "${BASH_SOURCE[0]}")/../config/template-consumers.yml}"
DEFAULT_OWNER="${GITHUB_OWNER:-Interested-Deving-1896}"
TARGETS_FILE=$(mktemp)
trap 'rm -f "$TARGETS_FILE"' EXIT

if ! python3 "$(dirname "${BASH_SOURCE[0]}")/template_cleanup_registry.py" \
  --default-owner "$DEFAULT_OWNER" "$REGISTRY_FILE" > "$TARGETS_FILE"; then
  echo "ERROR: consumer registry could not be resolved; refusing to inspect targets." >&2
  exit 2
fi

# ── Main ──────────────────────────────────────────────────────────────────────

echo "DRY RUN — report only; no files will be deleted"
echo ""
while IFS=$'\t' read -r org repo; do
  [[ -z "$org" || -z "$repo" ]] && continue
  budget_check "${org}/${repo}" || break
  echo "=== ${org}/${repo} ==="
  gh_cleanup_repo "$org" "$repo"
done < "$TARGETS_FILE"

echo ""
echo "GitLab: skipped — the consumer registry has no explicit GitLab target records."
echo ""
echo "cleanup-pollution: report complete — deleted=0 kept=${skipped_total} failed=${failed_total}"
[[ "$failed_total" -gt 0 ]] && exit 1
budget_report
exit 0
