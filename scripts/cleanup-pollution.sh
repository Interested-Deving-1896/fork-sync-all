#!/usr/bin/env bash
#
# Produces a non-destructive report of candidate paths that may have been
# incorrectly propagated from fork-sync-all. Path presence alone is not
# ownership evidence; every candidate still requires per-repository history audit.
#
# Targets come only from enabled, managed entries in config/template-consumers.yml.
# Bare names use Interested-Deving-1896; qualified names preserve their owner.
#
# Efficiency: fetches each registered repo's recursive Git tree once and
# intersects it with the candidate-path inventory. Truncated or invalid trees
# are skipped rather than treated as complete.
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

candidate_total=0
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
# One tree fetch per repo, then report only present candidate files.

gh_cleanup_repo() {
  local org="$1" repo="$2"
  local candidates=0 skipped=0 failed=0

  local tree_json
  tree_json=$(curl --disable --silent "${GH_AUTH[@]}" \
    "${GH_API}/repos/${org}/${repo}/git/trees/HEAD?recursive=1" 2>/dev/null)

  local tree_state
  tree_state=$(printf '%s' "$tree_json" | python3 -c '
import json,sys
try:
    data=json.load(sys.stdin)
except Exception:
    print("invalid")
    raise SystemExit
if not isinstance(data,dict) or not isinstance(data.get("tree"),list):
    print("invalid")
elif data.get("truncated"):
    print("truncated")
elif data.get("message"):
    print("error:" + str(data["message"]))
else:
    print("ok")
' 2>/dev/null) || tree_state="invalid"
  if [[ "$tree_state" != "ok" ]]; then
    echo "  SKIP ${org}/${repo}: tree unavailable or incomplete (${tree_state})" >&2
    (( failed++ )) || true
    failed_total=$((failed_total + failed))
    return
  fi

  local present
  present=$(printf '%s' "$tree_json" | python3 -c "
import sys, json
tree = json.load(sys.stdin).get('tree', [])
by_path = {item['path'] for item in tree if item.get('type') == 'blob'}
pollution = set($(printf '"%s"\n' "${ALL_POLLUTION_PATHS[@]}" | \
  python3 -c "import sys; lines=[l.strip().strip('\\"') for l in sys.stdin if l.strip()]; print('[' + ','.join(repr(l) for l in lines) + ']')"))
for path in sorted(pollution):
    if path in by_path:
        print(path)
" 2>/dev/null) || {
    echo "  SKIP ${org}/${repo}: could not parse repository tree" >&2
    (( failed++ )) || true
    failed_total=$((failed_total + failed))
    return
  }

  [[ -z "$present" ]] && return
  local hit_count
  hit_count=$(printf '%s\n' "$present" | wc -l | tr -d ' ')
  echo "  ${org}/${repo} (${hit_count} unverified candidate path(s))"

  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    if should_keep "$repo" "$path"; then
      echo "    KEEP (legacy manual exception; not ownership evidence): ${path}"
      (( skipped++ )) || true
      continue
    fi
    echo "    [report-only] candidate; ownership history not yet verified: ${path}"
    (( candidates++ )) || true
  done <<< "$present"

  echo "    → candidates=${candidates} legacy-keeps=${skipped} failed=${failed}"
  candidate_total=$((candidate_total + candidates))
  skipped_total=$((skipped_total + skipped))
  failed_total=$((failed_total + failed))
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
echo "cleanup-pollution: report complete — unverified_candidates=${candidate_total} legacy_keeps=${skipped_total} failed=${failed_total}"
[[ "$failed_total" -gt 0 ]] && exit 1
budget_report
exit 0
