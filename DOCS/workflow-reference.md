# Workflow Reference

All 72 workflows in `.github/workflows/`, grouped by function. For trigger
details see [`docs/workflow-triggers.md`](../docs/workflow-triggers.md)
(auto-generated). For priority tiers see
[`config/workflow-priority-tiers.yml`](../config/workflow-priority-tiers.yml).

---

## Sync and mirror

| Workflow | Schedule | Description |
|---|---|---|
| `sync-forks.yml` | Daily `06:00` | Syncs all I-D-1896 forks with their upstream parents |
| `sync-pieroproietti-forks.yml` | Every 4h `:05` | Fast-path sync for pieroproietti forks only |
| `sync-registered-imports.yml` | Every 6h `:55` | Re-syncs all repos in `registered-imports.json` |
| `sync-upstream-sources.yml` | Every 6h | Syncs upstream source repos into I-D-1896 |
| `mirror-to-osp.yml` | Every 6h `:00` | Mirrors I-D-1896 repos into OpenOS-Project-OSP |
| `mirror-osp-to-ooc.yaml` | Every 2h `:15` | Mirrors OSP repos into OpenOS-Project-Ecosystem-OOC |
| `mirror-osp-to-gitlab.yml` | Every 4h `:30` | Mirrors OSP repos into GitLab openos-project |
| `sync-from-gitlab.yml` | Daily `04:22` | Pulls GitLab repos back into I-D-1896 |
| `sync-to-gitlab.yml` | On push | Pushes I-D-1896 repos to GitLab |
| `sync-to-gitlab-variant.yml` | On push | Variant sync for specific mirror configurations |
| `mirror-orgs-full.yml` | Scheduled | Full org-to-org mirror pass |
| `mirror-orgs-watchdog.yml` | Scheduled | Detects and repairs broken org mirrors |
| `sync-registry-sources.yml` | Scheduled | Registry-driven upstream sync |

---

## Import

| Workflow | Trigger | Description |
|---|---|---|
| `import-repo.yml` | Manual | Imports any git repo from any platform into I-D-1896 |
| `clone-org.yml` | Manual | Clones all repos from a GitHub org into I-D-1896 |
| `merge-to-monorepo.yml` | Manual | Merges multiple repos into a single monorepo with preserved history |

### `import-repo.yml` inputs

| Input | Description | Default |
|---|---|---|
| `repo_url` | Source URL (any git host) | required |
| `repo_name` | Name in I-D-1896 | _(source name)_ |
| `mirror_to_osp_ooc` | Push through OSP → OOC chain immediately | `false` |
| `ongoing_sync` | Register in `registered-imports.json` | `false` |

When `ongoing_sync=true`, an immediate `sync-registered-imports` dispatch fires
after registration — no need to wait for the 6h schedule.

### `merge-to-monorepo.yml` inputs

| Input | Description | Default |
|---|---|---|
| `source_urls` | Newline-separated list of source repo URLs | required |
| `monorepo_name` | Name for the new monorepo in I-D-1896 | required |
| `subdirs` | Newline-separated subdirectory names (one per source) | _(repo names)_ |
| `mirror_monorepo` | Register monorepo in OSP mirror chain after merge | `false` |
| `use_git_lfs` | Enable Git LFS for large files | `false` |
| `nparent` | Use `--no-parent` merge strategy | `false` |

---

## Quota and queue management

| Workflow | Schedule | Description |
|---|---|---|
| `full-chain-flush.yml` | On `validate-config` success / manual | Master orchestrator — runs the full mirror + README + sync chain |
| `pre-flush-prep.yml` | Manual | Pre-flight for full-chain-flush: clear queue, merge PRs, validate, dispatch |
| `critical-deploy.yml` | Manual | Fast-lane: commit + push → aggressive queue clear → priority dispatch |
| `queue-manager.yml` | Every 15 min | Deduplicates queued runs; evicts runs queued > 25 min |
| `quota-reserve.yml` | Every 10 min | Cancels low-priority runs when quota < 1000 |
| `quota-monitor.yml` | Every 10 min | Monitors quota; triggers `rate-limit-rerun` on reset |
| `rate-limit-status.yml` | Manual | Reports current quota status |
| `cancel-stale-runs.yml` | Scheduled / manual | Cancels stale queued runs |
| `cancel-post-rotation.yml` | After token rotation | Cancels in-flight runs that used the old token |

### `pre-flush-prep.yml` inputs

| Input | Description | Default |
|---|---|---|
| `skip_merge_prs` | Skip auto-merging green PRs | `false` |
| `skip_cleanup` | Skip branch and run cleanup | `false` |
| `quota_wait_min` | Minimum quota before proceeding | `60` |

See [Pre-Flush Checklist](pre-flush-checklist.md) for the full pre-flight procedure.

---

## README management

| Workflow | Schedule | Description |
|---|---|---|
| `create-readmes.yml` | Scheduled / manual | Creates missing READMEs across OSP-bound repos |
| `update-readmes.yml` | Scheduled / manual | Regenerates AI-owned sections in existing READMEs |
| `translate-readmes.yml` | Scheduled | Translates READMEs into configured languages |
| `lts-readmes.yml` | Scheduled | Standardises READMEs on the LTS branch |
| `validate-readme-render.yml` | On push / PR | Checks README for rendering issues |
| `readme-wizard.yml` | Manual | Interactive README creation/update |
| `inject-badges.yml` | Scheduled | Injects "Built with Ona" badges into READMEs |

README sections use AI markers (`<!-- AI:start:section-name -->`) for the 8
AI-owned sections. Human-owned sections are never overwritten. See
[`AGENTS.md`](../AGENTS.md#readme-management) for the full marker format.

---

## Validation and CI

| Workflow | Trigger | Description |
|---|---|---|
| `validate-config.yml` | On push / PR | Validates all config files; runs AgentShield security scan (opt-in) |
| `validate-readme-render.yml` | On push / PR | Checks README for broken rendering |
| `check-osp-ci.yml` | Scheduled / manual | Checks CI status of OSP-bound repos |
| `check-gitlab-sync.yml` | Scheduled | Verifies GitLab mirrors are in sync |
| `ci.yml` | On push / PR | ShellCheck, Python lint, config validation |
| `enforce-agnostic-vendor.yml` | On push / PR touching `vendor/` | Scans vendor/ for distro-specific hardcoded defaults |

---

## Security and token management

| Workflow | Schedule | Description |
|---|---|---|
| `token-health.yml` | Weekly Monday `09:00` | Checks PAT expiry; opens issue at 45 days out |
| `rotate-token.yml` | Manual | Rotates any repo secret via workflow dispatch |
| `cancel-post-rotation.yml` | After rotation | Cancels in-flight runs using the old token |

See [`AGENTS.md`](../AGENTS.md#token-rotation) for rotation procedures.

---

## Maintenance

| Workflow | Schedule | Description |
|---|---|---|
| `reconcile-org-refs.yml` | Manual / on push | Rewrites org names in file content across all three orgs |
| `upstream-commits.yml` | Every 6h `:47` | Detects direct commits to OSP/OOC; opens PRs in I-D-1896 |
| `upstream-prs.yml` | Every 6h `:33` | Syncs open PRs from OSP/OOC into I-D-1896 |
| `add-mirror-repo.yml` | Manual | Adds a repo to the OSP + OOC mirror chain |
| `setup-osp-mirrors.yml` | Manual | Injects mirror workflow into all OSP repos |
| `cleanup-branches.yml` | Scheduled | Removes stale branches |
| `cleanup-pollution.yml` | Scheduled | Removes template pollution from non-consumer repos |
| `rebase-prs.yml` | Scheduled / manual | Rebases open PRs onto main |
| `resolve-failures.yml` | Daily `07:30` | AI-assisted CI failure resolver (GitHub Models) |
| `upstream-workflow-proposal.yml` | Weekly Monday `06:00` | Proposes new upstream workflows as template skeletons |
| `generate-dep-graph.yml` | Scheduled | Generates dependency graph across OSP repos |
| `repo-manifest.yml` | Scheduled | Generates repo manifest for OSP |
| `update-infra-deps.yml` | Scheduled | Updates GitHub Actions versions across workflows |
| `update-workflow-triggers-doc.yml` | On push | Regenerates `docs/workflow-triggers.md` |
| `org-storage-maintenance.yml` | Scheduled | Storage housekeeping across openos-project |
| `gl-storage-scan.yml` | Scheduled | Scans GitLab storage usage |

---

## OTA system

| Workflow | Trigger | Description |
|---|---|---|
| `ota-opt-in.yml` | Manual (in fork) | Creates `.ota/config.yml` and opens registration PR |
| `ota-discover.yml` | Daily `06:38` | Scans for new opt-ins; adds to registry |
| `ota-release.yml` | On semver tag push | Assembles and delivers OTA payloads to all opted-in repos |
| `ota-self-update.yml` | Scheduled (in fork) | Applies pending OTA updates in the fork |

See [OTA System](ota-system.md) for the full lifecycle and configuration reference.

---

## Specialised

| Workflow | Trigger | Description |
|---|---|---|
| `sync-btrfs-devel-branches.yml` | Scheduled | Syncs btrfs development branches |
| `sync-eggs-docs-to-book.yml` | On push | Syncs penguins-eggs docs into penguins-eggs-book |
| `fork-neon-repos.yml` | Manual | Forks KDE Neon repos into I-D-1896 |
| `docker-to-incus.yml` | Scheduled | Converts Docker artifacts to Incus format |
| `mirror-artifacts.yml` | Scheduled / on release | Mirrors release artifacts (packages, containers, flatpaks) |
| `mirror-releases.yml` | On release | Mirrors GitHub Releases across orgs |
| `trigger-artifact-mirror.yml` | Manual | Manually triggers artifact mirroring for a specific repo |
| `setup-gitlab-schedules.yml` | Manual | Creates scheduled pipelines in GitLab projects |
| `notify-poller.yml` | Scheduled | Polls for notifications and dispatches responses |
| `pr-automation.yml` | On PR events | Auto-labels, assigns, and manages PRs |
| `sync-template.yml` | On push / scheduled | Syncs template files to consumer repos |
| `shallow-reclone-chromium.yml` | Manual | Shallow re-clones large Chromium GitLab mirrors |
| `list-chromium-repos.yml` | Manual | Lists Chromium repos in GitLab |
