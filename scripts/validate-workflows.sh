#!/usr/bin/env bash
#
# validate-workflows.sh
#
# Guards the sync-template propagation pipeline against accidental workflow
# pollution. Checks that every file in .github/workflows/ is on the known-good
# allowlist before any outbound sync runs.
#
# Exit codes:
#   0 — all workflows are on the allowlist (propagation may proceed)
#   1 — one or more unknown workflows found (propagation must be blocked)
#
# Usage:
#   bash scripts/validate-workflows.sh
#   bash scripts/validate-workflows.sh --warn-only   # exit 0 but print warnings
#
# The allowlist is the single source of truth. To add a new workflow:
#   1. Add it to ALLOWED_WORKFLOWS below
#   2. Ensure it is agnostic (no hardcoded project names, repos, or orgs —
#      those belong in env vars or workflow_dispatch inputs)
#   3. Commit both the workflow and the allowlist update together

set -uo pipefail

WARN_ONLY=false

# ── Budget guard ─────────────────────────────────────────────────────────────
source "$(dirname "${BASH_SOURCE[0]}")/includes/budget.sh"
budget_init

[[ "${1:-}" == "--warn-only" ]] && WARN_ONLY=true

WORKFLOWS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.github/workflows"

# ── Allowlist ─────────────────────────────────────────────────────────────────
# Every workflow in .github/workflows/ must appear here.
# Grouped by function for readability.

ALLOWED_WORKFLOWS=(
  # ── Core infrastructure ──────────────────────────────────────────────────
  "sync-template.yml"           # propagates fork-sync-all template to consumers
  "validate-config.yml"         # validates config/ files and runs pytest suite
  "rate-limit-status.yml"       # reports current API quota across all tokens
  "runner-status.yml"           # hourly + post-queue-manager: runner utilisation and queue depth report
  "rate-limit-rerun.yml"        # re-triggers rate-limit-failed runs after reset
  "token-health.yml"            # weekly PAT expiry check
  "rotate-token.yml"            # token rotation helper
  "pr-automation.yml"           # auto-label, auto-assign, stale PR management
  "update-infra-deps.yml"       # weekly GitHub Actions version bumps

  # ── Mirror chain ─────────────────────────────────────────────────────────
  "mirror-to-osp.yml"           # Interested-Deving-1896 → OpenOS-Project-OSP
  "mirror-osp-to-ooc.yml"       # OpenOS-Project-OSP → OpenOS-Project-Ecosystem-OOC
  "mirror-osp-to-gitlab.yml"    # OSP → gitlab.com/openos-project
  "mirror-orgs-full.yml"        # daily full mirror sweep across all orgs
  "mirror-orgs-watchdog.yml"    # retries failed mirror runs
  "mirror-releases.yml"         # mirrors GitHub Releases across orgs
  "mirror-artifacts.yml"        # mirrors workflow artifacts across orgs
  "trigger-artifact-mirror.yml" # manual trigger for artifact mirror

  # ── Fork / import management ──────────────────────────────────────────────
  "sync-forks.yml"              # daily fork sync (all forks → upstream)
  "sync-registered-imports.yml" # daily sync of registered-imports.json entries (04:55 UTC)
  "sync-pieroproietti-forks.yml"# daily sync of pieroproietti upstream forks
  "sync-upstream-sources.yml"   # daily sync of upstream source refs
  "sync-from-gitlab.yml"        # deprecated stub — superseded by git-platform-sync.yml (direction=pull)
  "sync-to-gitlab.yml"          # deprecated stub — superseded by git-platform-sync.yml (direction=push)
  "import-repo.yml"             # manual: import a new repo into the pipeline
  "add-mirror-repo.yml"         # manual: add a repo to the OSP mirror chain
  "clone-org.yml"               # manual: bulk-clone an org into the pipeline
  "fork-neon-repos.yml"         # manual: import KDE Neon repos (plug-and-play)

  # ── README / documentation ────────────────────────────────────────────────
  "create-readmes.yml"          # daily: generate missing READMEs
  "update-readmes.yml"          # daily: refresh AI-owned README sections
  "translate-readmes.yml"       # daily: translate READMEs to English
  "validate-readme-render.yml"  # on push/post-update: check README rendering correctness
  "lts-readmes.yml"             # monthly: standardise LTS README sections
  "readme-wizard.yml"           # manual: AI-guided README authoring
  "readme-subsystem.yml"        # validate and cross-port the forge-neutral README subsystem
  "readme-subsystem-status.yml" # daily: audit subsystem drift and Pages health
  "mirror-readme-audit.yml"     # weekly: audit every live mirror-chain README
  "update-book-index.yml"       # push/manual: regenerate mdBook pages and index

  # ── CI / failure resolution ───────────────────────────────────────────────
  "resolve-failures.yml"        # daily: re-trigger failed workflow runs
  "notify-poller.yml"           # every 15min: poll for CI failure notifications
  "check-gitlab-sync.yml"       # manual: verify GitLab mirror is in sync

  # ── Repo maintenance ──────────────────────────────────────────────────────
  "cleanup-branches.yml"        # monthly: delete merged/stale branches
  "reconcile-org-refs.yml"      # daily: rewrite org references in mirror repos
  "inject-badges.yml"           # daily: inject built-with-ona badges
  "setup-osp-mirrors.yml"       # manual: ensure OSP mirror repos are configured
  "setup-gitlab-schedules.yml"  # manual: configure GitLab CI schedules
  "repo-manifest.yml"           # manual: generate repo manifest

  # ── Specialised sync workflows (plug-and-play skeletons) ─────────────────
  "sync-registry-sources.yml"       # agnostic: sync a repo's feature branch + registry-declared upstreams
  "rebase-lts.yml"              # skeleton: rebase a feature branch onto upstream default
  "sync-btrfs-devel-branches.yml" # skeleton: sync branches between repos
  "sync-eggs-docs-to-book.yml"  # skeleton: sync docs/ from one repo to another
  "upstream-commits.yml"        # push direct commits from mirrors back upstream
  "upstream-prs.yml"            # open upstream PRs for mirror commits
  "upstream-workflow-proposal.yml" # weekly: propose new OSP-bound workflows as template skeletons

  # ── Utility / one-shot ────────────────────────────────────────────────────
  "cleanup-pollution.yml"       # manual: remove incorrectly propagated template files from consumer repos
  "docker-to-incus.yml"         # manual: replace Docker artifacts with Incus equivalents across org repos
  "generate-dep-graph.yml"      # weekly: generate dependency graph
  "gl-storage-scan.yml"         # manual: scan GitLab storage usage
  "list-chromium-repos.yml"     # manual: list Chromium GitLab repos
  "shallow-reclone-chromium.yml"        # manual: shallow-reclone large GitLab mirrors to reclaim storage
  "merge-to-monorepo.yml"       # manual: merge repos into a monorepo

  # ── Audited repository workflows ────────────────────────────────────────
  # These workflows are intentionally local to FSA or selectively exported
  # through template-manifest.yml. Keeping them explicit here prevents a new
  # workflow from silently entering any propagation path.
  "a11y-pr-gate.yml"
  "agent-budget-governor.yml"
  "audit-arch-repos.yml"
  "auto-merge-prs.yml"
  "bdfs-dev-btrfs.yml"
  "bdfs-dev-dwarfs.yml"
  "bdfs-dev-overlay.yml"
  "bdfs-dev.yml"
  "bdfs-package.yml"
  "book-export.yml"
  "bootstrap-org.yml"
  "branch-hygiene-report.yml"
  "btrfs-devel-sync.yml"
  "bugzilla-failure-report.yml"
  "bugzilla-milestone-ship.yml"
  "build-arm64.yml"
  "build-selfhosted.yml"
  "build-x86.yml"
  "build.yml"
  "cancel-stale-runs.yml"
  "check-accessibility.yml"
  "check-ci.yml"
  "check-ooc-ci.yml"
  "check-shell-tools-ci.yml"
  "checks.yml"
  "ci.yaml"
  "clear-notifications.yml"
  "codeql-analysis.yml"
  "create-ooc-subgroups.yml"
  "critical-deploy-all.yml"
  "critical-deploy-github-ooc.yml"
  "critical-deploy-github-osp.yml"
  "critical-deploy-gitlab.yml"
  "critical-deploy-stub.yml"
  "critical-deploy.yml"
  "delete-stale-repos.yml"
  "dependency-risk-audit.yml"
  "deploy-book.yml"
  "devcontainer-sdk.yml"
  "dwarfs-pack-caller.yml"
  "eco-audit.yml"
  "enforce-agnostic-vendor.yml"
  "flush-active-watchdog.yml"
  "flush-lifecycle.yml"
  "forge-readme-parity.yml"
  "fsa-api.yml"
  "full-audit.yml"
  "full-chain-flush.yml"
  "gen-arch-config.yml"
  "generate-book-pages.yml"
  "generate-notebooklm.yml"
  "generate-repo-descriptions.yml"
  "generate-sbom.yml"
  "git-platform-sync.yml"
  "gitbook-oss.yml"
  "hw-detect-ci.yml"
  "inject-motto.yml"
  "integrate-shell-tools.yml"
  "labeler.yml"
  "list-active-runs.yml"
  "manage-repo-settings.yml"
  "manage-subtrees.yml"
  "merge-ready-prs.yml"
  "mirror-chain-dispatch.yml"
  "mirror-flatpak.yml"
  "mirror-ghcr.yml"
  "mirror-osp-to-ooc.yaml"
  "mirror-pypi.yml"
  "mirror-rpm.yml"
  "mirror.yaml"
  "notify-manager.yml"
  "onboard-bugzilla.yml"
  "onboard-repo.yml"
  "opencode.yml"
  "org-storage-maintenance.yml"
  "ota-discover.yml"
  "ota-opt-in.yml"
  "ota-reconcile.yml"
  "ota-release.yml"
  "ota-self-update.yml"
  "pin-manager.yml"
  "pin-workflows.yml"
  "pipeline-telemetry.yml"
  "post-flush-prep.yml"
  "pr-gate.yml"
  "pr-lifecycle-guard.yml"
  "pre-flush-prep.yml"
  "pre-mirror-ci-gate.yml"
  "provision-maintenance.yml"
  "push-kernel-content.yml"
  "queue-manager.yml"
  "quota-monitor.yml"
  "quota-reserve.yml"
  "rebase-prs.yml"
  "reconcile-identity-assets.yml"
  "refresh-notebooklm-auth.yml"
  "release.yaml"
  "resolve-ci.yml"
  "seed-patchset-branches.yml"
  "setup-dashboard-vars.yml"
  "support-bundle.yml"
  "sync-agent-prices.yml"
  "sync-fsa-forks.yml"
  "sync-in.yml"
  "sync-kde-groups-mirrors.yml"
  "sync-kde-neon-mirrors.yml"
  "sync-ona-projects.yml"
  "sync-pieroproietti-forks.yml"
  "sync-pieroproietti-gl-forks.yml"
  "sync-registry-backend.yml"
  "sync-shell-tools.yml"
  "sync-to-bugzilla.yml"
  "sync-to-gitlab-variant.yml"
  "sync-uaa-vendor.yml"
  "sync-upstream-mirrors.yml"
  "test-time-format.yml"
  "track-agent-costs.yml"
  "translate-docs.yml"
  "trigger-readme-update.yml"
  "update-kde-builder-vendor.yml"
  "update-quota-costs.yml"
  "update-workflow-triggers-doc.yml"
  "upload-asset.yml"
  "upload-notebooklm.yml"
  "upstream-contribute-caller.yml"
  "verify-fork-integrity.yml"
  "verify-mirror-integrity.yml"
  "vouch-check-pr.yml"
  "vouch-manage.yml"
  "vouch-onboard.yml"
  "vouch-sync-codeowners.yml"
  "workflow-completion-router.yml"
)

# ── Check ─────────────────────────────────────────────────────────────────────

found_unknown=false

while IFS= read -r -d '' wf_path; do
    budget_check "$wf_path" || break
  wf_name=$(basename "$wf_path")
  found=false
  for allowed in "${ALLOWED_WORKFLOWS[@]}"; do
    if [[ "$wf_name" == "$allowed" ]]; then
      found=true
      break
    fi
  done
  if [[ "$found" == "false" ]]; then
    echo "UNKNOWN WORKFLOW: $wf_name" >&2
    echo "  This file is not on the allowlist in scripts/validate-workflows.sh." >&2
    echo "  If it belongs here, add it to ALLOWED_WORKFLOWS and ensure it is" >&2
    echo "  agnostic (no hardcoded project names, repos, or org names)." >&2
    echo "  If it does not belong here, remove it before propagating." >&2
    found_unknown=true
  fi
done < <(find "$WORKFLOWS_DIR" -maxdepth 1 \( -name "*.yml" -o -name "*.yaml" \) -print0 | sort -z)

if [[ "$found_unknown" == "true" ]]; then
  if [[ "$WARN_ONLY" == "true" ]]; then
    echo "WARNING: unknown workflows found — propagation would be blocked in strict mode." >&2
    exit 0
  fi
  echo "ERROR: unknown workflows found — blocking propagation." >&2
  exit 1
fi

echo "validate-workflows: all $(find "$WORKFLOWS_DIR" -maxdepth 1 \( -name "*.yml" -o -name "*.yaml" \) | wc -l | tr -d ' ') workflows are on the allowlist."
budget_report
exit 0
