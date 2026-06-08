# Quota Cost Registry

GitHub's REST API allows 5,000 requests per hour per user (shared across all tokens belonging to the same user). This page documents how many REST calls each workflow consumes per run, the minimum quota required before a workflow should start, and how the quota management system uses this data.

GraphQL counts as 1 call regardless of how many repos are queried. `raw.githubusercontent.com` fetches are exempt entirely.

---

## How quota is managed

Three mechanisms work together:

| Mechanism | Where | What it does |
|---|---|---|
| `quota-reserve.sh` | Runs every 30 min | Cancels queued low-priority runs when `remaining < RESERVE_FLOOR` (default: 1000). Uses `min_quota` per workflow to also cancel runs that couldn't succeed with current quota even if they started. |
| `budget_check()` | Inside each script loop | Stops processing mid-run when time budget is exhausted. Prevents a single run from consuming all quota in one shot. |
| `workflow_min_quota()` | Pre-flight steps | Returns the `min_quota` for a workflow from `config/workflow-quota-costs.yml`. Workflows can use this to skip themselves when quota is too low. |

The single source of truth for costs is [`config/workflow-quota-costs.yml`](../config/workflow-quota-costs.yml).

---

## Cost table

Costs are estimated from code audit (Phase 1). Phase 2 will replace these with observed p50/p95 values from actual run measurements.

`min_quota` = minimum REST calls required before this workflow should be allowed to start.

### Tier 1 — Critical (never cancelled)

| Workflow | min_quota | Low | Mid | High | Notes |
|---|---|---|---|---|---|
| Rotate Secret Token | 50 | 5 | 10 | 20 | Token validation + secret update |
| Queue Manager | 50 | 5 | 15 | 30 | Queued run list + cancel calls |
| Quota Reserve | 10 | 1 | 5 | 15 | rate_limit check (exempt) + cancels |
| Rate-Limit Re-trigger | 50 | 5 | 20 | 50 | Failed run scan + dispatch calls |
| Token Health Monitor | 50 | 5 | 10 | 20 | Token validation only |
| CI | 50 | 2 | 5 | 10 | ShellCheck + lint, minimal API |
| Pre-Flush Prep | 100 | 10 | 30 | 60 | PR list + check-run queries |

### Tier 2 — High

| Workflow | min_quota | Low | Mid | High | Notes |
|---|---|---|---|---|---|
| Mirror Interested-Deving-1896 → OSP | 500 | 20 | 80 | 200 | 2 GraphQL + 1 REST/repo (check-runs, gated) |
| Mirror OSP → GitLab | 300 | 5 | 20 | 50 | 1 GraphQL for repo list; GitLab calls exempt |
| Sync Registered Imports | 200 | 5 | 15 | 30 | 1 GraphQL prefetch; REST only for new repos |
| Sync All Forks | 500 | 50 | 200 | 500 | 1 GraphQL + 1 REST merge-upstream per fork |
| Full Chain Flush | 1000 | 100 | 400 | 1000 | Orchestrates chain — cost is additive |
| Add Mirror Repo | 200 | 10 | 30 | 60 | Repo creation + webhook + dispatch |

### Tier 3 — Medium

| Workflow | min_quota | Low | Mid | High | Notes |
|---|---|---|---|---|---|
| Update READMEs | 300 | 50 | 150 | 300 | Tree fetch + file reads/writes per repo |
| Create Missing READMEs | 200 | 20 | 80 | 200 | Same as Update READMEs, subset of repos |
| Inject Built-with-Ona Badges | 200 | 5 | 30 | 80 | 1 GraphQL (repo list + README); REST only on write |
| Reconcile Org References | 300 | 10 | 60 | 150 | 1 GraphQL repo list; pushedAt from cache |
| Check OSP-Bound CI Status | 300 | 50 | 150 | 300 | 4 REST/repo (check-runs not in GraphQL) |
| Rebase PRs | 100 | 5 | 20 | 50 | PR list + rebase trigger |
| Sync btrfs-devel Branches | 100 | 5 | 20 | 50 | Branch sync per tracked branch |
| Sync pieroproietti Forks | 100 | 10 | 40 | 100 | merge-upstream per fork branch |
| Setup OSP Mirror Workflows | 200 | 20 | 80 | 200 | 1 GraphQL + workflow/secrets per repo (not in GraphQL) |
| Upstream PRs from OSP + OOC | 200 | 20 | 80 | 200 | PR creation/update per diverged repo |
| Upstream Direct Commits from OSP + OOC | 200 | 20 | 80 | 200 | Commit compare + PR creation |
| Sync to GitLab | 100 | 5 | 20 | 50 | GitHub reads; GitLab writes exempt |
| Sync to GitLab Variant | 100 | 5 | 20 | 50 | Same as Sync to GitLab |
| Sync from GitLab | 100 | 5 | 20 | 50 | GitLab reads + GitHub writes |
| Notification Poller | 50 | 1 | 5 | 15 | Single notifications call + optional dispatch |

### Tier 4 — Low (cancelled first)

| Workflow | min_quota | Low | Mid | High | Notes |
|---|---|---|---|---|---|
| Translate READMEs | 100 | 10 | 40 | 100 | File read + write per README |
| LTS README Standardisation | 100 | 10 | 40 | 100 | File read + write per LTS repo |
| Generate OSP Dependency Graph | 100 | 20 | 60 | 150 | README + package.json reads per repo |
| Upstream Workflow Proposal | 50 | 5 | 20 | 50 | Workflow file reads + PR creation |
| Update Infrastructure Dependencies | 50 | 5 | 15 | 30 | Dependabot config + PR creation |
| Mirror Artifacts | 200 | 10 | 50 | 150 | 2 GraphQL; release asset downloads exempt |
| Mirror Releases | 200 | 10 | 50 | 150 | 2 GraphQL + 1 REST releases list per repo |
| Cleanup Stale Branches | 200 | 10 | 60 | 200 | 1 GraphQL + 1 REST compare per branch |
| OTA Discover | 100 | 10 | 40 | 100 | Fork list + config reads per fork |
| OTA Self-Update | 50 | 5 | 15 | 30 | Config read + PR creation |
| Mirror Orgs | 100 | 20 | 60 | 150 | Repo list + description reads per org |
| Resolve CI Failures | 100 | 10 | 40 | 100 | Failed run list + job details + file writes |

---

## Daily quota budget

At 5,000 calls/hour reset, the effective daily budget depends on how many resets are consumed cleanly vs. drained by backlog. With the schedule reductions applied (June 2026), the expected daily workflow run count dropped by ~172 runs/day.

| Category | Before | After |
|---|---|---|
| `quota-reserve` runs/day | 144 | 48 |
| `queue-manager` runs/day | 96 | 48 |
| `notify-poller` runs/day | 12 | 6 |
| `rate-limit-rerun` runs/day | 12 | 6 |
| `mirror-artifacts` runs/day | 6 | 3 |
| `mirror-osp-to-gitlab` runs/day | 6 | 3 |
| `sync-pieroproietti-forks` runs/day | 6 | 3 |
| `sync-to-gitlab-variant` runs/day | 6 | 3 |

---

## REST → GraphQL conversion log

Scripts converted from per-repo REST loops to batched GraphQL calls:

| Script | Savings/run | Runs/day | Saved/day |
|---|---|---|---|
| `sync-registered-imports.sh` | ~100 | 4 | ~400 |
| `mirror-osp-to-gitlab.sh` | ~2 | 3 | ~6 |
| `reconcile-org-refs.sh` | ~100 | 6 | ~600 |
| `inject-badges.sh` | ~50 | 3 | ~150 |
| `cleanup-branches.sh` | ~200 | 1 | ~200 |
| `mirror-releases.sh` | ~50 | 4 | ~200 |
| `mirror-artifacts.sh` | ~50 | 3 | ~150 |
| `ota-discover.sh` | ~50 | 1 | ~50 |
| `mirror-orgs.sh` | ~60 | 1 | ~60 |
| `setup-osp-mirrors.sh` | ~100 | 4 | ~400 |
| **Total** | | | **~2,216/day** |

---

## Phase 2: observed cost tracking (planned)

Phase 2 will add lightweight instrumentation to measure actual REST consumption per run:

1. `scripts/includes/quota-instrument.sh` — records `remaining_before` and `remaining_after` as workflow step summary annotations
2. `update-quota-costs.yml` — weekly workflow that reads the last 30 run summaries via GraphQL, computes p50/p95 per workflow, and commits updated values back to `config/workflow-quota-costs.yml` with `basis: observed`

Once Phase 2 is active, the tables above will show observed values alongside the code-audit estimates, and `quota-reserve.sh` will automatically use the more accurate figures.
