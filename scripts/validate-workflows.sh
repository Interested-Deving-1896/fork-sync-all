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
  "rate-limit-rerun.yml"        # re-triggers rate-limit-failed runs after reset
  "token-health.yml"            # weekly PAT expiry check
  "rotate-token.yml"            # token rotation helper
  "pr-automation.yml"           # auto-label, auto-assign, stale PR management
  "update-infra-deps.yml"       # weekly GitHub Actions version bumps

  # ── Mirror chain ─────────────────────────────────────────────────────────
  "mirror-to-osp.yml"           # Interested-Deving-1896 → OpenOS-Project-OSP
  "mirror-osp-to-ooc.yaml"      # OpenOS-Project-OSP → OpenOS-Project-Ecosystem-OOC
  "mirror-osp-to-gitlab.yml"    # OSP → gitlab.com/openos-project
  "mirror-orgs-full.yml"        # daily full mirror sweep across all orgs
  "mirror-orgs-watchdog.yml"    # retries failed mirror runs
  "mirror-releases.yml"         # mirrors GitHub Releases across orgs
  "mirror-artifacts.yml"        # mirrors workflow artifacts across orgs
  "trigger-artifact-mirror.yml" # manual trigger for artifact mirror

  # ── Fork / import management ──────────────────────────────────────────────
  "sync-forks.yml"              # daily fork sync (all forks → upstream)
  "sync-registered-imports.yml" # hourly sync of registered-imports.json entries
  "sync-pieroproietti-forks.yml"# hourly sync of pieroproietti upstream forks
  "sync-upstream-sources.yml"   # daily sync of upstream source refs
  "sync-from-gitlab.yml"        # daily pull from GitLab → GitHub
  "sync-to-gitlab.yml"          # daily push from GitHub → GitLab
  "import-repo.yml"             # manual: import a new repo into the pipeline
  "add-mirror-repo.yml"         # manual: add a repo to the OSP mirror chain
  "clone-org.yml"               # manual: bulk-clone an org into the pipeline
  "fork-neon-repos.yml"         # manual: import KDE Neon repos (plug-and-play)

  # ── README / documentation ────────────────────────────────────────────────
  "create-readmes.yml"          # daily: generate missing READMEs
  "update-readmes.yml"          # daily: refresh AI-owned README sections
  "translate-readmes.yml"       # daily: translate READMEs to English
  "lts-readmes.yml"             # monthly: standardise LTS README sections
  "readme-wizard.yml"           # manual: AI-guided README authoring

  # ── CI / failure resolution ───────────────────────────────────────────────
  "resolve-failures.yml"        # daily: re-trigger failed workflow runs
  "notify-poller.yml"           # every 15min: poll for CI failure notifications
  "check-gitlab-sync.yml"       # manual: verify GitLab mirror is in sync

  # ── Repo maintenance ──────────────────────────────────────────────────────
  "cleanup-branches.yml"        # monthly: delete merged/stale branches
  "reconcile-org-refs.yml"      # daily: rewrite org references in mirror repos
  "inject-badges.yml"           # daily: inject built-with-ona badges
  "setup-osp-mirrors.yml"       # hourly: ensure OSP mirror repos are configured
  "setup-gitlab-schedules.yml"  # manual: configure GitLab CI schedules
  "repo-manifest.yml"           # manual: generate repo manifest

  # ── Specialised sync workflows (plug-and-play skeletons) ─────────────────
  "rebase-lts.yml"              # skeleton: rebase a feature branch onto upstream default
  "sync-btrfs-devel-branches.yml" # skeleton: sync branches from one repo to another
  "sync-eggs-docs-to-book.yml"  # skeleton: sync docs/ from one repo to another
  "upstream-commits.yml"        # push direct commits from mirrors back upstream
  "upstream-prs.yml"            # open upstream PRs for mirror commits
  "upstream-workflow-proposal.yml" # weekly: propose new OSP-bound workflows as template skeletons

  # ── Utility / one-shot ────────────────────────────────────────────────────
  "cleanup-pollution.yml"       # manual: remove incorrectly propagated template files from consumer repos
  "generate-dep-graph.yml"      # weekly: generate dependency graph
  "gl-storage-scan.yml"         # manual: scan GitLab storage usage
  "list-chromium-repos.yml"     # manual: list Chromium GitLab repos
  "shallow-reclone-chromium.yml"# manual: shallow-reclone Chromium mirrors
  "merge-to-monorepo.yml"       # manual: merge repos into a monorepo
  "sync-btrfs-devel-branches.yml" # skeleton: sync branches between repos
)

# ── Check ─────────────────────────────────────────────────────────────────────

found_unknown=false

while IFS= read -r -d '' wf_path; do
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
done < <(find "$WORKFLOWS_DIR" -maxdepth 1 -name "*.yml" -o -name "*.yaml" | sort -z)

if [[ "$found_unknown" == "true" ]]; then
  if [[ "$WARN_ONLY" == "true" ]]; then
    echo "WARNING: unknown workflows found — propagation would be blocked in strict mode." >&2
    exit 0
  fi
  echo "ERROR: unknown workflows found — blocking propagation." >&2
  exit 1
fi

echo "validate-workflows: all $(find "$WORKFLOWS_DIR" -maxdepth 1 \( -name "*.yml" -o -name "*.yaml" \) | wc -l | tr -d ' ') workflows are on the allowlist."
exit 0
