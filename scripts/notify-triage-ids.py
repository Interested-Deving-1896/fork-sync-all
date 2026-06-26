#!/usr/bin/env python3
"""
scripts/notify-triage-ids.py — print notification IDs matching known-safe patterns
Usage: notify-triage-ids.py <notifs.json>
Prints one notification thread ID per line for notifications whose subject
title matches a known-safe auto-triage pattern.

Patterns cover all five supported git platforms:
  GitHub, GitLab, Gitea, Forgejo, Codeberg
"""
import json, sys

# ── GitHub workflow / automation noise ───────────────────────────────────────
# Workflow run notifications appear as the workflow's `name:` field.
# These are expected, recurring, and do not require human review.
GITHUB_WORKFLOW_PATTERNS = [
    # Mirror chain
    'Mirror Interested-Deving-1896 → OSP',
    'Mirror to OpenOS-Project-Ecosystem-OOC',
    'Mirror OSP → GitLab',
    'Mirror Chain Dispatch',
    'Mirror Watchdog',
    'Mirror Releases',
    'Mirror Artifacts',
    'Mirror Flatpak Repo',
    'Mirror GHCR Images',
    'Mirror PyPI Packages',
    'Mirror RPM Repo',
    'Mirror Orgs',
    # Sync operations
    'Sync All Forks',
    'Sync FSA Forks',
    'Sync btrfs-devel Branches',
    'Sync Registered Imports',
    'Sync Shell Tools Vendor',
    'Sync UAA Vendor',
    'Sync Template',
    'Sync Upstream Mirrors',
    'Sync Upstream Sources',
    'Sync from GitLab',
    'Sync to GitLab',
    'Sync KDE Groups Mirrors',
    'Sync KDE Neon Mirrors',
    'Sync Pieroproietti GitLab Forks',
    'Sync pieroproietti Forks',
    'Sync Ona Projects',
    'Sync Agent Prices',
    'Sync Registry Backend',
    'Sync Registry Sources',
    'btrfs-devel sync',
    # Flush pipeline
    'Flush Lifecycle Manager',
    'Full Chain Flush',
    'Pre-Flush Prep',
    'Post-Flush Verification',
    'Flush Active Watchdog',
    'Critical Deploy',
    'GitLab Critical Deploy',
    # README / docs
    'Update READMEs',
    'Create Missing READMEs',
    'Translate READMEs',
    'Translate Docs',
    'LTS README Standardisation',
    'README Wizard',
    'Generate Book Pages',
    'Update Book Index',
    'Deploy Book',
    'Export Book',
    'Generate NotebookLM Content',
    'Upload NotebookLM Assets',
    'Refresh NotebookLM Auth',
    'Sync penguins-eggs docs',
    # Quota / rate-limit management
    'Rate Limit Status',
    'Rate-Limit Re-trigger',
    'Quota Monitor',
    'Quota Reserve',
    'Queue Manager',
    'Cancel Stale Runs',
    'Cancel Runs After Token Rotation',
    # CI / checks
    'Check CI Status',
    'Check OSP CI Status',
    'Check OOC CI Status',
    'Check Shell Tools CI',
    'Check GitLab CI Sync',
    'Pre-Mirror CI Gate',
    'Verify Mirror Integrity',
    'Verify Fork Integrity',
    'Validate Config',
    'Pipeline Telemetry',
    # Notifications (self-referential)
    'Notification Manager',
    'Notification Poller',
    'Clear All Notifications',
    # Maintenance
    'Cleanup Stale Branches',
    'Cleanup Template Pollution',
    'Branch Hygiene Report',
    'Inject Built-with-Ona Badges',
    'Inject Repo Motto',
    'Reconcile Org References',
    'Manage Repo Settings',
    'Manage Subtrees',
    'Org Storage Maintenance',
    'GitLab Storage Scan',
    'Delete Stale Repos',
    'Rotate Secret Token',
    'Token Health Monitor',
    'Pin Manager',
    'Pin Workflow Actions',
    'Update Infrastructure Dependencies',
    'Update Quota Cost Registry',
    'Update Workflow Triggers Doc',
    'Track Agent Costs',
    'Sync-in',
    'OTA Reconcile',
    'OTA Self-Update',
    'OTA Discover',
    'OTA Opt-In',
    'OTA Release',
    'Integrate Shell Tools',
    'Rebase PRs',
    'Auto-merge PRs',
    'Merge Ready PRs',
    'PR Automation',
    'PR Labeler',
    'PR Lifecycle Guard',
    'PR Gate',
    'Upstream Contribute',
    'Upstream Direct Commits',
    'Upstream PRs from OSP',
    'Upstream Workflow Proposal',
    'Onboard Repository',
    'Import Repository',
    'Add Mirror Repo',
    'Generate OSP Dependency Graph',
    'Generate Repo Descriptions',
    'Generate SBOM',
    'Generate architecture config',
    'Repo Manifest',
    'Eco Audit',
    'Full Audit',
    'Audit Arch Repos',
    'Runner Status',
    'Setup Dashboard Variables',
    'Setup GitLab CI Schedules',
    'Setup OSP Mirror Workflows',
    'Provision GitLab Maintenance Schedules',
    'Create OOC GitLab Subgroups',
    'Shallow Reclone Large GitLab Mirrors',
    'Resolve CI Failures',
    'Git Platform Sync',
    'Bootstrap Triggers',
    'Devcontainer SDK',
    'Enforce Agnostic Vendor',
    'FSA API',
    'Vouch Check PR',
    'Vouch Manage',
    'Vouch Sync Codeowners',
    'Accessibility PR Gate',
    'Check Accessibility',
    'Validate README Render',
    'Trigger README Update',
    'Trigger Artifact Mirror',
    'Rebuild LTS Branch',
    'Seed Patchset Branches',
    'Push Kernel Content',
    'Fork KDE Neon Repos',
    'List Chromium GitLab Repos',
    'Clone Org',
    'Merge Repos into Monorepo',
    'Docker → Incus Migration',
    'BDFS Dev',
    'bdfs Package',
    'DwarFS Pack Release',
    'HW Detect CI',
    'Build',
    'CodeQL',
    'Checks',
    'CI',
    'opencode',
    'Test Time Format',
    'GitBook OSS',
    'Update kde-builder vendor',
]

# ── Dependency-update bots ────────────────────────────────────────────────────
DEPENDENCY_PATTERNS = [
    'Dependabot',
    'dependabot',
    'chore(deps)',
    'chore: bump',
    'build(deps)',
    'fix(deps)',
    'deps: bump',
    'deps: update',
    'renovate',
    'Renovate',
    'deps-update',
    'Update dependencies',
    'update dependencies',
    'Bump ',
    'bump ',
]

# ── Rate-limit / quota strings ────────────────────────────────────────────────
QUOTA_PATTERNS = [
    'Rate limit',
    'rate limit',
    'rate-limit',
    'Rate-limit',
    'Quota',
    'quota',
    'quota exhausted',
    'API limit',
]

# ── GitLab CI / pipeline notifications ───────────────────────────────────────
# GitLab sends pipeline status emails/notifications with these subject patterns.
GITLAB_PATTERNS = [
    'Pipeline #',
    'pipeline #',
    'Pipeline failed',
    'Pipeline passed',
    'Pipeline succeeded',
    'CI/CD pipeline',
    'GitLab CI',
    'gitlab-ci',
    'Mirror from',
    'Mirroring',
    'mirroring',
    'Push to mirror',
    'mirror push',
    'Sync upstream',
    'sync upstream',
    'openos-project',
    'OpenOS-Project',
]

# ── Gitea / Forgejo / Codeberg mirror notifications ───────────────────────────
# These platforms emit notifications for mirror sync events and push activity.
GITEA_FORGEJO_CODEBERG_PATTERNS = [
    '[mirror]',
    'Mirror sync',
    'mirror sync',
    'Sync mirror',
    'sync mirror',
    'Mirror push',
    'mirror push',
    'Mirror pull',
    'mirror pull',
    'Mirrored from',
    'mirrored from',
    'Fork sync',
    'fork sync',
    'Upstream sync',
    'upstream sync',
    'codeberg.org',
    'Codeberg',
    'forgejo',
    'Forgejo',
    'gitea',
    'Gitea',
]

# ── Org-name patterns (cross-platform) ───────────────────────────────────────
# Notifications referencing our org names are from the mirror chain.
ORG_PATTERNS = [
    'OpenOS-Project-OSP',
    'OpenOS-Project-Ecosystem-OOC',
    'Interested-Deving-1896',
    'openos-project-osp',
    'openOS-project',
]

# ── Combined pattern list ─────────────────────────────────────────────────────
PATTERNS = (
    GITHUB_WORKFLOW_PATTERNS
    + DEPENDENCY_PATTERNS
    + QUOTA_PATTERNS
    + GITLAB_PATTERNS
    + GITEA_FORGEJO_CODEBERG_PATTERNS
    + ORG_PATTERNS
)

# ── Main ──────────────────────────────────────────────────────────────────────
notifs_file = sys.argv[1] if len(sys.argv) > 1 else '/tmp/notifs.json'

try:
    with open(notifs_file) as f:
        data = json.load(f)
except Exception as e:
    print(f'error reading {notifs_file}: {e}', file=sys.stderr)
    sys.exit(0)

for n in data:
    title = n.get('subject', {}).get('title', '')
    if any(p in title for p in PATTERNS):
        print(n['id'])
