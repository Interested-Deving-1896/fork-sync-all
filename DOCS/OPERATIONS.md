# Operational Reference: GitHub Actions Limits & Quotas

This document covers the GitHub Actions limits that affect fork-sync-all,
what consumes them, how to detect exhaustion, and how to recover.

---

## GitHub API Rate Limit

**Quota:** 5,000 requests/hour per authenticated user token.

**Resets:** Top of every hour (rolling window).

**What consumes it:**

| Operation | Cost |
|---|---|
| `gh api` / REST API call | 1 req |
| Listing workflow runs | 1 req per page |
| Cancelling a run | 1 req |
| Triggering a workflow dispatch | 1 req |
| Checking job status | 1 req per job |
| GraphQL query | Separate quota (5,000 points/hr) — unaffected by REST exhaustion |

**How fork-sync-all burns it:**
- Every `workflow_run` trigger fires a new run, which itself may call the API
- `rate-limit-rerun.yml` (formerly hourly) scans all recent failed runs
- `stuck-run-detector.yml` (formerly hourly) lists all queued/in-progress runs
- `translate-readmes.yml` was triggering after 10 workflows — each trigger
  consumed dozens of API calls for the org scan
- Bulk-cancelling queued runs during cleanup consumes ~1 req per cancel —
  if the queue is large and quota is already low, the cancel loop itself
  can exhaust the remaining quota

**Detecting exhaustion:**
```bash
gh api rate_limit --jq '.resources.core | "remaining: \(.remaining)/\(.limit)  resets: \(.reset | todate)"'
```

**Recovery:** Wait until the top of the next hour. GraphQL remains available
during REST exhaustion and can be used for read-only queries.

---

## GitHub Actions Runner Minutes

**Free tier:** 2,000 minutes/month. Resets on your **billing cycle date**
(the day of the month your GitHub account was created — check
**Settings → Billing → Actions** for the exact date).

**Paid:** Billed per minute beyond the free tier; Linux runners cost 1×,
Windows 2×, macOS 10×. All workflows in this repo use `ubuntu-latest` (Linux, 1×).

**What counts against the monthly quota:**

- Every job that runs on `ubuntu-latest` (GitHub-hosted runner)
- Time is measured from job start to job end, rounded up to the nearest minute
- Jobs that are *queued* but never start do **not** consume minutes
- Jobs that exit immediately (e.g. `if:` condition is false at the job level)
  still consume ~1 minute for runner provisioning

**What does NOT count:**

- `workflow_dispatch` triggers that are never clicked
- Runs that are cancelled before a job starts
- Skipped jobs (`if:` evaluated to false before the runner is assigned)
- Self-hosted runners (zero cost regardless of usage)

**How fork-sync-all was burning minutes (before May 2026 fixes):**

1. `mirror-orgs-watchdog` fired after every mirror completion (5 workflows ×
   hourly cadence = ~120 runs/day), each consuming ~1 min even on success
2. `update-readmes` triggered after 7 workflows including high-frequency syncs
3. `inject-badges` triggered after mirror workflows that run hourly
4. `stuck-run-detector` and `rate-limit-rerun` ran hourly as meta-workflows,
   each consuming minutes to manage other workflows
5. `workflow_run` listeners fired on every `completed` event (success, failure,
   cancelled) — not just on the outcomes they actually needed

**Detecting exhaustion:**

Symptoms (in order of appearance):
1. `ubuntu-latest` jobs queue but never start
2. No in-progress runs despite many queued
3. Runs queued for hours with 0 runners active
4. Billing API returns 404 (needs `user` OAuth scope — check web UI instead)

Check via GitHub web UI: **Settings → Billing → Actions**.

**Recovery:** Wait until the billing cycle reset date. In the meantime:
- Cancel all queued runs (they will never start)
- Do not push commits that trigger new workflow runs
- Use `workflow_dispatch` manually only for critical operations

---

## Concurrency Groups & Stuck Runs

**How they work:** A concurrency group allows only one run at a time for a
given key. If `cancel-in-progress: false`, a second run queues behind the
first. If the first run never finishes (e.g. runner minutes exhausted mid-job),
the queued run is permanently stuck.

**The cascade pattern:**
1. Runner minutes exhaust mid-job → job hangs in `in_progress`
2. Next scheduled run queues behind it (`cancel-in-progress: false`)
3. The in-progress run never finishes → queue grows indefinitely
4. API calls to cancel are themselves rate-limited → nothing can be cleared

**Orphaned runs:** A run can become permanently orphaned if it was triggered
from an older version of a workflow file that contained a job (e.g.
`Update cost profile`) that no longer exists in the current file. The run
accepts cancel API calls but GitHub immediately re-queues it because the
concurrency group from the old code is still technically active. These runs
time out automatically after GitHub's maximum queue wait (~6 hours). New
runs from the same workflow are not blocked — they use the current file.

**Policy in this repo (May 2026):** All workflows use `cancel-in-progress: true`
except those that perform multi-repo writes where mid-run cancellation would
leave state partially applied:

| Workflow | `cancel-in-progress` | Reason |
|---|---|---|
| `sync-template` | `false` | Propagates files to 35 repos — partial sync leaves repos inconsistent |
| `mirror-releases` | `false` | Partial mirror leaves releases incomplete |
| `lts-readmes` | `false` | Mid-run cancel leaves some repos un-standardised |
| `mirror-osp-to-gitlab` | `false` | Partial GitLab mirror |
| `create-readmes` | `false` | Mid-run cancel leaves some repos without READMEs |
| `mirror-artifacts` | `false` | Partial artifact mirror |
| All others | `true` | Newer run supersedes safely |

**Detecting stuck runs:**
```bash
gh api "repos/Interested-Deving-1896/fork-sync-all/actions/runs?per_page=100" \
  --jq '[.workflow_runs[] | select(.status == "queued")] | length'
```

**Bulk cancel (check quota first — cancel loop consumes ~1 req per run):**
```bash
gh api rate_limit --jq '.resources.core.remaining'

gh api "repos/Interested-Deving-1896/fork-sync-all/actions/runs?per_page=100" \
  --jq '[.workflow_runs[] | select(.status=="queued") | .id] | .[]' | \
  xargs -I{} gh api -X POST \
    "repos/Interested-Deving-1896/fork-sync-all/actions/runs/{}/cancel"
```

---

## workflow_run Trigger Cost Model

`workflow_run` fires on every `completed` event regardless of conclusion
(success, failure, cancelled, skipped). A listener that only needs to act
on failures still consumes a runner minute for every successful upstream run
unless gated at the job level.

**Pattern used in this repo:**

```yaml
# For workflows that act on upstream SUCCESS (content processors):
jobs:
  my-job:
    if: |
      github.event_name != 'workflow_run' ||
      github.event.workflow_run.conclusion == 'success'

# For workflows that act on upstream FAILURE (watchdogs/retriers):
jobs:
  retry:
    if: |
      github.event_name == 'workflow_dispatch' ||
      github.event.workflow_run.conclusion == 'failure'
```

This exits immediately (no runner cost) when the conclusion doesn't match,
while keeping the trigger automatic.

**All workflow_run listeners and their gates (May 2026):**

| Workflow | Gate |
|---|---|
| `mirror-orgs-watchdog` | `conclusion == 'failure'` |
| `create-readmes` | `conclusion == 'success'` |
| `inject-badges` | `conclusion == 'success'` |
| `lts-readmes` | `conclusion == 'success'` |
| `mirror-osp-to-gitlab` | `conclusion == 'success'` |
| `translate-readmes` | `conclusion == 'success'` (on gate job) |
| `update-readmes` | `conclusion == 'success'` |
| `dwarfs-pack-caller` | `conclusion == 'success'` |
| `rebase-lts` | `conclusion == 'success'` |

---

## Current Workflow Schedule Summary

Schedules as of June 2026. All times UTC (24h) / UTC (12h) / ET (EDT, UTC−4).
See `DOCS/workflow-scheduling.md` for full per-workflow quota and window details.

| Workflow | 24h UTC | 12h UTC | ET (EDT) | Cadence | Notes |
|---|---|---|---|---|---|
| `mirror-to-osp` | :13 | :13 AM/PM | −4h | Every 6h | Core mirror chain start |
| `mirror-osp-to-ooc` | :45 | :45 AM/PM | −4h | Every 6h | 32 min after mirror-to-osp |
| `sync-in` | :37 | :37 AM/PM | −4h | Every 6h + daily 10:15 | Health check + workspace sync |
| `auto-merge-prs` | :55 | :55 AM/PM | −4h | Every 6h | |
| `queue-manager` | :00/:30 | :00/:30 AM/PM | −4h | Every 30 min | Infrastructure |
| `quota-reserve` | :00/:30 | :00/:30 AM/PM | −4h | Every 30 min | Infrastructure |
| `mirror-releases` | 00:03 + 12:03 | 12:03 AM + 12:03 PM | 8:03 PM + 8:03 AM | Every 12h | |
| `sync-pieroproietti-forks` | 01:07 | 1:07 AM | 9:07 PM | Daily | Reduced from 8h |
| `mirror-osp-to-gitlab` | 01:23 | 1:23 AM | 9:23 PM | Daily | Reduced from 8h |
| `sync-to-gitlab-variant` | 01:50 | 1:50 AM | 9:50 PM | Daily | Reduced from 8h |
| `mirror-artifacts` | 02:10 | 2:10 AM | 10:10 PM | Daily | Reduced from 8h |
| `mirror-orgs-full` | 02:17 | 2:17 AM | 10:17 PM | Daily | |
| `setup-osp-mirrors` | 02:45 | 2:45 AM | 10:45 PM | Daily | Reduced from 6h |
| `upstream-prs` | 03:33 | 3:33 AM | 11:33 PM | Daily | Reduced from 6h |
| `upstream-commits` | 03:47 | 3:47 AM | 11:47 PM | Daily | Reduced from 6h |
| `git-platform-sync` | 04:27 + 09:23 | 4:27 AM + 9:23 AM | 12:27 AM + 5:23 AM | Daily ×2 | Pull + push |
| `sync-registered-imports` | 04:55 | 4:55 AM | 12:55 AM | Daily | Reduced from 6h |
| `sync-btrfs-devel-branches` | 05:02 | 5:02 AM | 1:02 AM | Daily | Reduced from 6h |
| `rebase-prs` | 05:10 | 5:10 AM | 1:10 AM | Every 2 days | Reduced from daily |
| `flush-lifecycle` | Sun 06:00 | 6:00 AM Sun | 2:00 AM Sun | Weekly + manual | Top-level pipeline entry point |
| `full-chain-flush` | 05:17 | 5:17 AM | 1:17 AM | Monthly (1st) + via flush-lifecycle | Triggered by flush-lifecycle or pre-flush-prep |
| `reconcile-org-refs` | 05:50 | 5:50 AM | 1:50 AM | Every 2 days | Reduced from daily |
| `resolve-ci` | 07:43 | 7:43 AM | 3:43 AM | Daily | |
| `check-ci` | 09:05 | 9:05 AM | 5:05 AM | Daily | 1,500 quota floor |
| `check-shell-tools-ci` | 09:30 | 9:30 AM | 5:30 AM | Daily | |
| `inject-badges` | 08:15 | 8:15 AM | 4:15 AM | Every 2 days | Reduced from daily |
| `translate-readmes` | 10:43 | 10:43 AM | 6:43 AM | Every 2 days | Reduced from daily |
| `translate-docs` | 11:15 | 11:15 AM | 7:15 AM | Every 2 days | Reduced from daily |
| `refresh-notebooklm-auth` | 06:17 Tue | 6:17 AM Tue | 2:17 AM Tue | Weekly | |
| `update-infra-deps` | 06:11 Mon | 6:11 AM Mon | 2:11 AM Mon | Weekly | |

**Estimated daily drain:** ~3,200 REST calls/day (~133/hr average).
Worst hourly burst: ~612 calls at 03:xx UTC / 3 AM UTC / 11 PM ET.
Headroom at worst hour: ~4,388 calls (well within 5,000/hr limit).

For optimal manual dispatch windows, see `DOCS/workflow-scheduling.md`.

---

## Self-Hosted Runner Setup (Recommended)

To eliminate the monthly minute cap entirely, add a self-hosted runner:

1. Go to **Settings → Actions → Runners → New self-hosted runner**
2. Follow the setup instructions for your host OS
3. Change workflow `runs-on` from `ubuntu-latest` to `self-hosted` (or add
   a label and use that label)

Self-hosted runners have no minute cost and no concurrent job cap beyond
what the host machine can handle.

---

## Quick Reference: Limit Reset Times

| Limit | Resets |
|---|---|
| GitHub API rate limit (REST) | Top of every hour |
| GitHub API rate limit (GraphQL) | Top of every hour (separate quota) |
| GitHub Actions minutes | Billing cycle date (check Settings → Billing) |
| GitHub Actions concurrent jobs (free) | N/A — blocked by minute exhaustion |
