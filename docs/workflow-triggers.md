# Workflow Triggers

All workflows in `.github/workflows/`. Grouped by function, with every trigger listed.

> Plain-text version: [`docs/workflow-triggers.txt`](workflow-triggers.txt)

---

## Mirror Chain

| Workflow | File | Schedule | Also triggers on |
|---|---|---|---|
| Mirror Interested-Deving-1896 → OSP | `mirror-to-osp.yml` | Every 6h at `:00` | dispatch |
| Mirror to OpenOS-Project-Ecosystem-OOC | `mirror-osp-to-ooc.yaml` | Every 6h at `:15` | dispatch |
| Mirror OSP → GitLab | `mirror-osp-to-gitlab.yml` | Every 4h at `:30` | `Add Mirror Repo` completes · dispatch |
| Mirror Orgs | `mirror-orgs-full.yml` | Daily 02:00 | dispatch |
| Mirror Releases | `mirror-releases.yml` | Every 6h at `:03` | dispatch |
| Mirror Artifacts | `mirror-artifacts.yml` | Every 4h at `:10` | dispatch |
| Mirror Watchdog | `mirror-orgs-watchdog.yml` | — | `Mirror I-D-1896 → OSP`, `Mirror Orgs`, `Mirror OSP → GitLab`, `Mirror Releases`, `Mirror Artifacts` complete |

---

## OSP-Bound Repo Management

| Workflow | File | Schedule | Also triggers on |
|---|---|---|---|
| Add Mirror Repo | `add-mirror-repo.yml` | — | dispatch (provide repo URL) |
| Check OSP-Bound CI Status | `check-osp-ci.yml` | Daily 09:00 | `Mirror I-D-1896 → OSP` completes · `Add Mirror Repo` completes · dispatch |
| Setup OSP Mirror Workflows | `setup-osp-mirrors.yml` | Every 6h at `:45` | dispatch |

---

## Fork & Import Sync

| Workflow | File | Schedule | Also triggers on |
|---|---|---|---|
| Sync All Forks | `sync-forks.yml` | Daily 06:00 | dispatch |
| Sync pieroproietti Forks | `sync-pieroproietti-forks.yml` | Every 4h at `:05` | dispatch |
| Sync Registered Imports | `sync-registered-imports.yml` | Every 6h at `:55` | dispatch |
| Import Repository | `import-repo.yml` | — | dispatch (provide source URL) |
| Sync Upstream Sources | `sync-upstream-sources.yml` | Daily 01:30 | dispatch |
| Sync btrfs-devel Branches | `sync-btrfs-devel-branches.yml` | Every 6h at `:00` | dispatch |
| Sync Registry Sources | `sync-registry-sources.yml` | Daily 03:05 | dispatch |
| Sync from GitLab | `sync-from-gitlab.yml` | Daily 04:22 | dispatch |
| Upstream PRs from OSP + OOC | `upstream-prs.yml` | Every 6h at `:33` | dispatch |
| Upstream Direct Commits from OSP + OOC | `upstream-commits.yml` | Every 6h at `:47` | dispatch |

---

## GitLab Sync

| Workflow | File | Schedule | Also triggers on |
|---|---|---|---|
| Sync to GitLab | `sync-to-gitlab.yml` | Daily 09:17 | dispatch |
| Sync to GitLab Variant | `sync-to-gitlab-variant.yml` | Every 4h at `:50` | push to `config/ota-registry.yml`, `config/ota-blocklist.yml`, `.ota/schema.yml`, `CHANGELOG.md`, `config/template-manifest.yml` · dispatch |

---

## README Management

| Workflow | File | Schedule | Also triggers on |
|---|---|---|---|
| Update READMEs | `update-readmes.yml` | Daily 03:00 | push to `config/gitlab-subgroups.yml`, `config/template-manifest.yml` · `Sync Registered Imports` completes · dispatch |
| Create Missing READMEs | `create-readmes.yml` | Daily 07:08 | `Add Mirror Repo`, `Import Repository`, `Clone Org`, `Merge Repos into Monorepo` complete · dispatch |
| Translate READMEs | `translate-readmes.yml` | Daily 10:30 | `Update READMEs` completes · dispatch |
| LTS README Standardisation | `lts-readmes.yml` | Monthly 1st 03:00 | `Rebuild LTS Branch (penguins-eggs)` completes · dispatch |
| Validate README Render | `validate-readme-render.yml` | — | push to `README.md` · `Update READMEs` completes · dispatch |
| README Wizard | `readme-wizard.yml` | — | dispatch |
| Inject Built-with-Ona Badges | `inject-badges.yml` | Daily 08:15 | `Mirror OSP → GitLab` completes · dispatch |

---

## CI & Failure Resolution

| Workflow | File | Schedule | Also triggers on |
|---|---|---|---|
| Resolve CI Failures | `resolve-failures.yml` | Daily 07:30 | dispatch (also triggered automatically by Notification Poller) |
| Notification Poller | `notify-poller.yml` | Every 2h at `:30` | dispatch |
| Rate-Limit Re-trigger | `rate-limit-rerun.yml` | Every 2h at `:05` | dispatch |
| Rebuild LTS Branch (penguins-eggs) | `rebase-lts.yml` | — | `Sync pieroproietti Forks` completes · dispatch |
| PR Automation | `pr-automation.yml` | — | pull_request (opened, synchronize, reopened, ready_for_review) |

---

## Maintenance & Housekeeping

| Workflow | File | Schedule | Also triggers on |
|---|---|---|---|
| Reconcile Org References | `reconcile-org-refs.yml` | Daily 05:50 | dispatch |
| Full Chain Flush | `full-chain-flush.yml` | Monthly 1st 05:00 | dispatch (optional dry_run, skip_readmes) |
| Cleanup Stale Branches | `cleanup-branches.yml` | Monthly 1st 04:00 | dispatch |
| Cleanup Template Pollution | `cleanup-pollution.yml` | — | dispatch |
| Sync Template | `sync-template.yml` | — | push to `.devcontainer/**`, `.ona/**`, `config/template-manifest.yml` · dispatch |
| Update Infrastructure Dependencies | `update-infra-deps.yml` | Weekly Mon 06:00 | dispatch |
| Upstream Workflow Proposal | `upstream-workflow-proposal.yml` | Weekly Mon 06:03 | dispatch |
| Generate OSP Dependency Graph | `generate-dep-graph.yml` | Weekly Sun 03:00 | dispatch |
| Token Health Monitor | `token-health.yml` | Weekly Mon 09:00 | dispatch |
| Rotate Secret Token | `rotate-token.yml` | — | dispatch (select secret, provide new value) |
| Validate Config | `validate-config.yml` | — | push to config files · pull_request · dispatch |

---

## Utility / On-Demand

| Workflow | File | Trigger |
|---|---|---|
| Cancel Stale Runs | `cancel-stale-runs.yml` | dispatch |
| Quota Monitor | `quota-monitor.yml` | dispatch |
| Rate Limit Status | `rate-limit-status.yml` | dispatch |
| Clone Org | `clone-org.yml` | dispatch |
| Fork KDE Neon Repos | `fork-neon-repos.yml` | dispatch |
| Merge Repos into Monorepo | `merge-to-monorepo.yml` | dispatch |
| Repo Manifest | `repo-manifest.yml` | dispatch |
| Sync penguins-eggs docs to penguins-eggs-book | `sync-eggs-docs-to-book.yml` | dispatch |
| Shallow Reclone Large GitLab Mirrors | `shallow-reclone-chromium.yml` | dispatch |
| GitLab Storage Scan | `gl-storage-scan.yml` | dispatch |
| Check GitLab CI Sync | `check-gitlab-sync.yml` | dispatch |
| List Chromium GitLab Repos | `list-chromium-repos.yml` | dispatch |
| Setup GitLab CI Schedules | `setup-gitlab-schedules.yml` | dispatch |
| Trigger Artifact Mirror | `trigger-artifact-mirror.yml` | programmatic only |

---

## Schedule Summary (UTC)

| Time | Frequency | Workflow |
|---|---|---|
| `:00` | every 6h | Mirror Interested-Deving-1896 → OSP |
| `:00` | every 6h | Sync btrfs-devel Branches |
| `:03` | every 6h | Mirror Releases |
| `:05` | every 4h | Sync pieroproietti Forks |
| `:05` | every 2h | Rate-Limit Re-trigger |
| `:10` | every 4h | Mirror Artifacts |
| `:15` | every 6h | Mirror to OOC |
| `:30` | every 2h | Notification Poller |
| `:30` | every 4h | Mirror OSP → GitLab |
| `:33` | every 6h | Upstream PRs from OSP + OOC |
| `:45` | every 6h | Setup OSP Mirror Workflows |
| `:47` | every 6h | Upstream Direct Commits |
| `:50` | every 4h | Sync to GitLab Variant |
| `:55` | every 6h | Sync Registered Imports |
| 01:30 | daily | Sync Upstream Sources |
| 02:00 | daily | Mirror Orgs |
| 03:00 | daily | Update READMEs |
| 03:05 | daily | Sync Registry Sources |
| 04:22 | daily | Sync from GitLab |
| 05:50 | daily | Reconcile Org References |
| 06:00 | daily | Sync All Forks |
| 07:08 | daily | Create Missing READMEs |
| 07:30 | daily | Resolve CI Failures |
| 08:15 | daily | Inject Built-with-Ona Badges |
| 09:00 | daily | Check OSP-Bound CI Status |
| 09:17 | daily | Sync to GitLab |
| 10:30 | daily | Translate READMEs |
| 06:00 | weekly Mon | Update Infrastructure Dependencies |
| 06:03 | weekly Mon | Upstream Workflow Proposal |
| 09:00 | weekly Mon | Token Health Monitor |
| 03:00 | weekly Sun | Generate OSP Dependency Graph |
| 03:00 | monthly 1st | LTS README Standardisation |
| 04:00 | monthly 1st | Cleanup Stale Branches |
| 05:00 | monthly 1st | Full Chain Flush |
