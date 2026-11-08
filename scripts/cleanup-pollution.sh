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
#   SYNC_TOKEN      — GitHub PAT with read access to registered consumer repositories
#   #
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

verified_total=0
unverified_total=0
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

# ── GitHub cleanup ────────────────────────────────────────────────────────────
# One tree fetch per repo, then report only present candidate files.

gh_cleanup_repo() {
  local org="$1" repo="$2"
  local unverified=0 verified=0
  local tree_json tree_state present hit_count

  tree_json=$(curl --disable --silent "${GH_AUTH[@]}" \
    "${GH_API}/repos/${org}/${repo}/git/trees/HEAD?recursive=1" 2>/dev/null)

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
    (( failed_total++ )) || true
    return
  fi

  present=$(printf '%s' "$tree_json" | python3 -c "
import sys, json
tree = json.load(sys.stdin).get('tree', [])
by_path = {item['path'] for item in tree if item.get('type') == 'blob'}
pollution = set($(printf '"%s"\\n' "${ALL_POLLUTION_PATHS[@]}" | \
  python3 -c "import sys; lines=[l.strip().strip('\\\"') for l in sys.stdin if l.strip()]; print('[' + ','.join(repr(l) for l in lines) + ']')"))
for path in sorted(pollution):
    if path in by_path:
        print(path)
" 2>/dev/null) || {
    echo "  SKIP ${org}/${repo}: could not parse repository tree" >&2
    (( failed_total++ )) || true
    return
  }

  [[ -z "$present" ]] && return
  hit_count=$(printf '%s\n' "$present" | wc -l | tr -d ' ')
  echo "  ${org}/${repo} (${hit_count} candidate path(s)); auditing full Git history"

  local temp_root clone_dir askpass audit_json audit_rows
  temp_root=$(mktemp -d)
  clone_dir="${temp_root}/repo"
  askpass="${temp_root}/git-askpass"
  cat > "$askpass" <<'ASKPASS'
#!/bin/sh
case "$1" in
  *Username*) printf '%s\n' 'x-access-token' ;;
  *Password*) printf '%s\n' "$SYNC_TOKEN" ;;
  *) exit 1 ;;
esac
ASKPASS
  chmod 700 "$askpass"

  if ! GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0 \
    git clone --filter=blob:none --no-checkout --no-tags --quiet \
      "https://github.com/${org}/${repo}.git" "$clone_dir" 2>/dev/null; then
    echo "    UNVERIFIED: full-history clone failed; no path is considered safe"
    unverified=$hit_count
    rm -rf "$temp_root"
    unverified_total=$((unverified_total + unverified))
    return
  fi

  if ! git -C "$clone_dir" read-tree HEAD 2>/dev/null; then
    echo "    UNVERIFIED: could not populate Git index from HEAD"
    unverified=$hit_count
    rm -rf "$temp_root"
    unverified_total=$((unverified_total + unverified))
    return
  fi

  local -a audit_args=(--repo "$clone_dir")
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    audit_args+=(--path "$path")
  done <<< "$present"

  audit_json=$(python3 "$(dirname "${BASH_SOURCE[0]}")/audit_template_file_ownership.py" "${audit_args[@]}" 2>/dev/null) || true
  audit_rows=$(printf '%s' "$audit_json" | python3 -c '
import json,sys
try:
    results=json.load(sys.stdin).get("results", [])
except Exception:
    raise SystemExit(1)
for item in results:
    fields = [
        "true" if item.get("eligible") else "false",
        str(item.get("path", "")),
        str(item.get("reason", "unknown")),
        str(item.get("baseline_commit", "")),
        str(item.get("evidence_commits", "")),
    ]
    print("\t".join(fields))
' 2>/dev/null) || audit_rows=""

  if [[ -z "$audit_rows" ]]; then
    echo "    UNVERIFIED: ownership auditor returned no parseable evidence"
    unverified=$hit_count
  else
    while IFS= read -r eligible path reason baseline evidence; do
      if [[ "$eligible" == "true" ]]; then
        echo "    OWNERSHIP VERIFIED (report only; baseline=${baseline}; commits=${evidence}): ${path}"
        (( verified++ )) || true
      else
        echo "    UNVERIFIED (${reason}): ${path}"
        (( unverified++ )) || true
      fi
    done <<< "$audit_rows"
  fi

  rm -rf "$temp_root"
  verified_total=$((verified_total + verified))
  unverified_total=$((unverified_total + unverified))
  echo "    → verified=${verified} unverified=${unverified}"
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
echo "cleanup-pollution: report complete — ownership_verified=${verified_total} ownership_unverified=${unverified_total} failed=${failed_total}"
[[ "$failed_total" -gt 0 ]] && exit 1
budget_report
exit 0
\t' read -r eligible path reason baseline evidence; do
      if [[ "$eligible" == "true" ]]; then
        echo "    OWNERSHIP VERIFIED (report only; baseline=${baseline}; commits=${evidence}): ${path}"
        (( verified++ )) || true
      else
        echo "    UNVERIFIED (${reason}): ${path}"
        (( unverified++ )) || true
      fi
    done <<< "$audit_rows"
  fi

  rm -rf "$temp_root"
  verified_total=$((verified_total + verified))
  unverified_total=$((unverified_total + unverified))
  echo "    → verified=${verified} unverified=${unverified}"
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
echo "cleanup-pollution: report complete — ownership_verified=${verified_total} ownership_unverified=${unverified_total} failed=${failed_total}"
[[ "$failed_total" -gt 0 ]] && exit 1
budget_report
exit 0
