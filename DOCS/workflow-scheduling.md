# Workflow Scheduling Guide

Optimal trigger windows, quota requirements, and timing constraints for every
scheduled workflow. Use this when deciding when to manually dispatch a workflow
or when to adjust a cron schedule.

---

## How to read this guide

**Quota cost** — REST API calls consumed per run (mid = typical, high = worst case).
Source: `config/workflow-quota-costs.yml`. GraphQL calls count as 1 REST call
regardless of how many repos are queried.

**Best window** — the UTC hour range where quota headroom is highest and
concurrency with other workflows is lowest.

**Avoid** — hours where the scheduled burst is already high or where a
dependency workflow hasn't finished yet.

**Quota floor** — the minimum remaining quota required before the workflow
will run (from `min_quota` in `config/workflow-quota-costs.yml`). If quota
is below this, the workflow skips itself and waits for the next reset.

---

## Time format note

Per-workflow tables show two schedule columns:
- **Schedule (UTC)** — 24h UTC, the authoritative cron time
- **Schedule (EST)** — EST (UTC−5, Nov–Mar). Add 1h for EDT (UTC−4, Mar–Nov).

Example: `09:05 UTC` = `4:05 AM EST` = `5:05 AM EDT`.

The timing map and "Best manual dispatch windows" tables use the full
`24h UTC / 12h UTC / 12h ET (EST/EDT)` format for completeness.

---

## Daily quota budget

| Metric | Value |
|---|---|
| Quota per hour | 5,000 REST calls |
| Scheduled drain (daily avg) | ~3,200 calls/day (~133/hr average) |
| Worst scheduled burst (03:xx UTC / 3:xx AM UTC / 10:xx PM ET) | ~612 calls in one hour |
| Headroom at worst hour | ~4,388 calls remaining |
| Safe manual dispatch window | Any hour with < 2,000 calls already consumed |

Check current quota before dispatching:
```bash
curl -sf -H "Authorization: token $SYNC_TOKEN" \
  "https://api.github.com/rate_limit" | \
  python3 -c "
import sys,json,datetime
d=json.load(sys.stdin)['resources']['core']
print(f\"remaining={d['remaining']}  resets={datetime.datetime.utcfromtimestamp(d['reset']).strftime('%H:%M UTC')}\")
"
```

---

## Scheduled workflow timing map

All times UTC (24h) with 12h UTC and approximate ET equivalents.
`[*/2]` = every other day (even days of month). `(*/30)` = every 30 min.

```
Hour (UTC)     12h UTC        ET (EDT/EST)    Workflows
─────────────────────────────────────────────────────────────────────────────
00:xx          12:xx AM       8:xx PM / 7:xx PM    mirror-to-osp (:13)  sync-in (:37)
                                                    mirror-osp-to-ooc (:45)  auto-merge-prs (:55)
01:xx          1:xx AM        9:xx PM / 8:xx PM    sync-pieroproietti-forks (:07)
                                                    mirror-osp-to-gitlab (:23)
                                                    sync-to-gitlab-variant (:50)
02:xx          2:xx AM        10:xx PM / 9:xx PM   mirror-artifacts (:10)  mirror-orgs-full (:17)
                                                    setup-osp-mirrors (:45)
03:xx          3:xx AM        11:xx PM / 10:xx PM  upstream-prs (:33)  upstream-commits (:47)
04:xx          4:xx AM        12:xx AM / 11:xx PM  git-platform-sync/pull (:27)
                                                    sync-registered-imports (:55)
05:xx          5:xx AM        1:xx AM / 12:xx AM   sync-btrfs-devel-branches (:02)
                                                    rebase-prs [*/2] (:10)
                                                    reconcile-org-refs [*/2] (:50)
06:xx          6:xx AM        2:xx AM / 1:xx AM    queue-manager (*/30)  quota-reserve (*/30)
                                                    [Mon only: update-infra-deps (:11)]
07:xx          7:xx AM        3:xx AM / 2:xx AM    resolve-ci (:43)
08:xx          8:xx AM        4:xx AM / 3:xx AM    check-ci (:05)  inject-badges [*/2] (:15)
09:xx          9:xx AM        5:xx AM / 4:xx AM    git-platform-sync/push (:23)
                                                    check-shell-tools-ci (:30)
10:xx          10:xx AM       6:xx AM / 5:xx AM    sync-in/daily (:15)
                                                    translate-readmes [*/2] (:43)
11:xx          11:xx AM       7:xx AM / 6:xx AM    translate-docs [*/2] (:15)
12:xx–23:xx    12:xx PM–      8:xx AM–             mirror-releases (:03 at 12:xx)
               11:xx PM       7:xx PM              queue-manager + quota-reserve (*/30, all hours)
```

---

## Per-workflow scheduling reference

### Core mirror chain

| Workflow | Schedule (UTC) | Schedule (EST) | Quota mid | Quota high | Floor | Best window (UTC) | Avoid |
|---|---|---|---|---|---|---|---|
| Mirror I-D-1896 → OSP | Every 6h at :13 | Every 6h at :13 | 80 | 200 | 300 | After 14:00 reset | 00:00–06:00 (busy) |
| Mirror OSP → OOC | Every 6h at :45 | Every 6h at :45 | 80 | 200 | 300 | 32 min after mirror-to-osp | Before :13 slot |
| Mirror Orgs | Daily 02:17 | Daily 9:17 PM | 60 | 150 | 200 | 02:00–04:00 | 06:xx (weekly burst) |
| Mirror OSP → GitLab | Daily 01:23 | Daily 8:23 PM | 80 | 200 | 200 | 01:00–03:00 | During mirror chain |
| Mirror Releases | Every 12h at :03 (00:03 + 12:03) | 7:03 PM + 7:03 AM | 100 | 300 | 200 | 00:03 or 12:03 | During flush |
| Mirror Artifacts | Daily 02:10 | Daily 9:10 PM | 80 | 200 | 200 | 02:00–04:00 | During flush |

**Mirror chain dependency order:** Mirror I-D-1896 → OSP must complete before
Mirror OSP → OOC. The :13/:45 stagger (32 min gap) is intentional — do not
reduce this gap when manually dispatching both.

---

### CI check + resolver

| Workflow | Schedule (UTC) | Schedule (EST) | Quota mid | Quota high | Floor | Best window (UTC) | Avoid |
|---|---|---|---|---|---|---|---|
| Check CI Status | Daily 09:05 | 4:05 AM | 300 | 900 | 1500 | 09:00–11:00 | During flush |
| Resolve CI Failures (Agnostic) | Daily 07:43 | 2:43 AM | 120 | 400 | 100 | 07:00–09:00 | During flush |
| Check Shell Tools CI | Daily 09:30 | 4:30 AM | 50 | 100 | 200 | 09:00–11:00 | — |

**Note:** Check CI Status requires a 1,500 quota floor — the highest of any
workflow. If quota is below 1,500 at 09:05 UTC (4:05 AM EST / 5:05 AM EDT),
it skips and waits for the next day. Manually dispatch after the 14:00 UTC
reset if you need it to run same-day.

---

### Sync operations

| Workflow | Schedule (UTC) | Schedule (EST) | Quota mid | Quota high | Floor | Best window (UTC) | Avoid |
|---|---|---|---|---|---|---|---|
| Sync All Forks | Via full-chain-flush | — | 200 | 500 | 500 | 04:00–08:00 | During mirror chain |
| Sync Registered Imports | Daily 04:55 | 11:55 PM | 45 | 100 | 200 | 04:00–06:00 | — |
| Sync btrfs-devel Branches | Daily 05:02 | 12:02 AM | 30 | 80 | 100 | 05:00–07:00 | — |
| Sync pieroproietti Forks | Daily 01:07 | 8:07 PM | 60 | 150 | 200 | 01:00–03:00 | — |
| Sync to GitLab Variant | Daily 01:50 | 8:50 PM | 40 | 100 | 100 | 01:00–03:00 | — |
| Setup OSP Mirror Workflows | Daily 02:45 | 9:45 PM | 80 | 200 | 200 | 02:00–04:00 | — |
| Git Platform Sync | Daily 04:27 + 09:23 | 11:27 PM + 4:23 AM | 60 | 150 | 200 | 04:00 or 09:00 | — |
| Upstream PRs from OSP+OOC | Daily 03:33 | 10:33 PM | 80 | 200 | 300 | 03:00–05:00 | — |
| Upstream Direct Commits | Daily 03:47 | 10:47 PM | 80 | 200 | 300 | After upstream-prs (:33) | Before :33 slot |

---

### README + badge operations

| Workflow | Schedule (UTC) | Schedule (EST) | Quota mid | Quota high | Floor | Best window (UTC) | Avoid |
|---|---|---|---|---|---|---|---|
| Update READMEs | Via flush | — | 150 | 400 | 500 | 10:00–12:00 | During mirror chain |
| Create Missing READMEs | Via flush | — | 100 | 300 | 300 | 10:00–12:00 | — |
| Inject Built-with-Ona Badges | Every 2 days 08:15 | 3:15 AM | 120 | 300 | 300 | 08:00–10:00 | — |
| Translate READMEs | Every 2 days 10:43 | 5:43 AM | 150 | 400 | 300 | 10:00–12:00 | — |
| Translate Docs | Every 2 days 11:15 | 6:15 AM | 100 | 250 | 200 | 11:00–13:00 | — |
| Reconcile Org References | Every 2 days 05:50 | 12:50 AM | 80 | 200 | 200 | 05:00–07:00 | — |

---

### Infrastructure / quota management

| Workflow | Schedule (UTC) | Schedule (EST) | Quota mid | Quota high | Floor | Notes |
|---|---|---|---|---|---|---|
| Queue Manager | Every 30 min | Every 30 min | 15 | 30 | 50 | Never manually dispatch — runs automatically |
| Quota Reserve | Every 30 min | Every 30 min | 15 | 30 | 50 | Never manually dispatch |
| Rate-Limit Re-trigger | Every 6h | Every 6h | 30 | 80 | 100 | Fires automatically after quota recovery |
| Auto-merge PRs | Every 6h at :55 (00:55, 06:55, 12:55, 18:55) | 7:55 PM, 1:55 AM, 7:55 AM, 1:55 PM | 30 | 80 | 100 | Safe to dispatch any time |
| Rebase PRs | Every 2 days 05:10 | 12:10 AM | 40 | 100 | 100 | Safe to dispatch any time |

---

### Heavy / manual-only workflows

| Workflow | Trigger | Schedule (EST) | Quota mid | Quota high | Floor | Best window (UTC) |
|---|---|---|---|---|---|---|
| Full Chain Flush | Manual / daily 05:17 | 12:17 AM | 400 | 1000 | 1000 | 04:00–08:00 |
| Pre-Flush Prep | Manual only | — | 50 | 150 | 3000 | 14:05 (5 min after reset) |
| Critical Deploy | Manual only | — | 100 | 300 | 500 | Any time — bypasses queue |
| Onboard Repo | Manual only | — | 80 | 200 | 300 | Any time |
| Add Mirror Repo | Manual only | — | 60 | 150 | 200 | Any time |

**Pre-Flush Prep** has the highest floor (3,000) because it validates config,
merges PRs, and then dispatches the full flush chain. Trigger it immediately
after the 14:00 UTC (9:00 AM EST / 10:00 AM EDT) reset for maximum headroom.

---

## Best manual dispatch windows

### Highest quota headroom

| Window | 24h UTC | 12h UTC | ET (EDT) | ET (EST) | Why |
|---|---|---|---|---|---|
| **Best** | 14:00–15:00 | 2:00–3:00 PM | 10:00–11:00 AM | 9:00–10:00 AM | Immediately after hourly reset; ~4,867 calls available |
| **Good** | 05:00–07:00 | 5:00–7:00 AM | 1:00–3:00 AM | 12:00–2:00 AM | Low scheduled activity; ~4,400 calls typically available |
| **Good** | 20:00–23:00 | 8:00–11:00 PM | 4:00–7:00 PM | 3:00–6:00 PM | No scheduled workflows; quota recovering |

### Lowest concurrency (fewest parallel jobs)

| Window | 24h UTC | 12h UTC | ET (EDT) | ET (EST) | Why |
|---|---|---|---|---|---|
| **Best** | 15:00–17:00 | 3:00–5:00 PM | 11:00 AM–1:00 PM | 10:00 AM–12:00 PM | No scheduled workflows at all |
| **Good** | 11:00–13:00 | 11:00 AM–1:00 PM | 7:00–9:00 AM | 6:00–8:00 AM | Only translate workflows (every 2 days); runners mostly idle |

### Avoid

| Window | 24h UTC | 12h UTC | ET (EDT) | ET (EST) | Why |
|---|---|---|---|---|---|
| **Worst** | 03:00–04:00 | 3:00–4:00 AM | 11:00 PM–12:00 AM | 10:00–11:00 PM | Highest burst (~612 calls); upstream PRs + commits + sync all fire |
| **Caution** | 06:00–07:00 | 6:00–7:00 AM | 2:00–3:00 AM | 1:00–2:00 AM | Monday only: 13-workflow concurrent spike (update-infra-deps) |
| **Caution** | 09:00–10:00 | 9:00–10:00 AM | 5:00–6:00 AM | 4:00–5:00 AM | Check CI Status fires (1,500 floor); marginal quota risks skipping it |

---

## Pre-flush-prep checklist

Before triggering `pre-flush-prep.yml`:

```bash
# 1. Check quota
curl -sf -H "Authorization: token $SYNC_TOKEN" \
  "https://api.github.com/rate_limit" | \
  python3 -c "
import sys,json,datetime
d=json.load(sys.stdin)['resources']['core']
reset=datetime.datetime.utcfromtimestamp(d['reset']).strftime('%H:%M UTC')
ok = '✅' if d['remaining'] >= 3000 else '❌'
print(f\"{ok} remaining={d['remaining']} (need 3000)  resets={reset}\")
"

# 2. Run validators locally
python3 scripts/validate-workflow-guards.py
python3 scripts/validate-gitlab-subgroups.py config/gitlab-subgroups.yml
python3 scripts/validate-registered-imports.py registered-imports.json
python3 scripts/validate-priority-tiers.py config/workflow-priority-tiers.yml
python3 scripts/validate-cost-profiles.py config/workflow-cost-profiles.yml

# 3. Check for open PRs that would block the flush
gh pr list --state open --json number,title,mergeable
```

**Ideal trigger time:**

| 24h UTC | 12h UTC | ET (EDT) | ET (EST) |
|---|---|---|---|
| 14:05 | 2:05 PM | 10:05 AM | 9:05 AM |

5 minutes after the hourly reset — maximum quota headroom before any
scheduled workflows consume from the fresh bucket.

---

## Quota drain reduction history

| Date | Change | Saving |
|---|---|---|
| 2026-06 | Removed schedule from check-osp-ci + check-ooc-ci stubs | −600/day |
| 2026-06 | auto-merge-prs: 2h → 6h | −240/day |
| 2026-06 | upstream-prs + upstream-commits: 6h → daily | −480/day |
| 2026-06 | setup-osp-mirrors: 6h → daily | −240/day |
| 2026-06 | sync-to-gitlab + sync-from-gitlab stubs: removed schedule | −0 cost, freed runner slots |
| 2026-06 | sync-btrfs-devel + sync-registered-imports: 6h → daily | −105/day |
| 2026-06 | mirror-releases: 6h → 12h | −100/day |
| 2026-06 | sync-to-gitlab-variant + sync-pieroproietti + mirror-osp-to-gitlab + mirror-artifacts: 8h → daily | −480/day |
| 2026-06 | reconcile-org-refs + rebase-prs + inject-badges + translate-readmes + translate-docs: daily → every 2 days | −300/day |
| **Total** | | **−2,545/day (−46% from 5,495 baseline)** |

Current baseline: **~3,200 calls/day** (~133/hr average).

---

## Remaining quota reduction opportunities

These are known but not yet applied — each has a trade-off noted.

| Opportunity | Potential saving | Trade-off |
|---|---|---|
| Convert `sync-forks.sh` REST repo loop → GraphQL prefetch | ~200/run | Code change required in script |
| Convert `reconcile-org-refs.sh` REST loop → GraphQL | ~100/run | Code change required |
| `mirror-releases.yml`: 12h → daily | ~50/day | Releases delayed up to 24h |
| `resolve-ci.yml`: remove daily schedule, trigger-only | ~60/day | Failures only resolved when check-ci fires |
| `check-shell-tools-ci.yml`: daily → every 2 days | ~25/day | Shell tools CI lag |
| Add `actions/cache@v5` to `full-audit.yml` (pyyaml) | runner time only | Trivial |
| Add `actions/cache@v5` to `check-accessibility.yml` (pa11y) | runner time only | Trivial |
| `sync-pieroproietti-gl-forks.sh`: migrate to `gh_get` | reliability | Raw curl has no retry |

---

## Speed improvement opportunities

### Scripts

| Script | Issue | Fix |
|---|---|---|
| `sync-forks.sh` | Sequential REST calls per repo | GraphQL prefetch for repo list + existence |
| `reconcile-org-refs.sh` | Paginated REST for org repos | GraphQL batch query |
| `update-readmes.sh` | Per-repo `/contents/README.md` calls | Tree fetch with `?recursive=1` then filter |
| `resolve-failures.sh` | Sequential per-repo run scan | Parallel with `xargs -P 4` for log fetches |
| `sync-pieroproietti-gl-forks.sh` | Raw `curl` without retry | Source `includes/gh-api.sh`, use `gh_get` |

### Workflows

| Workflow | Issue | Fix |
|---|---|---|
| `full-audit.yml` | `pip install pyyaml` on every run | Add `actions/cache@v5` |
| `check-accessibility.yml` | `npm install -g pa11y` on every run | Add `actions/cache@v5` |
| `validate-config.yml` | ✅ Already cached (pytest, yamllint, gavi) | — |
| `critical-deploy*.yml` | `fetch-depth: 0` (full history) | Only needed for `git log` — use `fetch-depth: 1` + `git fetch --unshallow` only when needed |
| `sync-shell-tools.yml` | `fetch-depth: 0` | Same as above |
| `manage-subtrees.yml` | `fetch-depth: 0` | Required for subtree — keep |
| `sync-uaa-vendor.yml` | `fetch-depth: 0` | Required for vendor merge — keep |

### Runner minutes

Public repos on GitHub get **unlimited free runner minutes**. If this repo is
public, runner minutes are not a constraint. If private:

- Current worst-case estimate: ~8,000 min/month (well over 2,000 free tier)
- Self-hosted runner eliminates the cap entirely
- Alternatively: reduce `timeout-minutes` on workflows that consistently
  finish in < 5 min but have 30 min timeouts — this doesn't save minutes
  (billing is actual runtime, not timeout) but prevents runaway jobs

**Workflows with oversized timeouts relative to typical runtime:**

| Workflow | timeout-minutes | Typical runtime | Suggested |
|---|---|---|---|
| Queue Manager | 10 | < 1 min | 5 |
| Quota Reserve | 10 | < 1 min | 5 |
| Auto-merge PRs | 15 | 1–3 min | 8 |
| Rebase PRs | 20 | 2–5 min | 10 |
| Reconcile Org Refs | 30 | 5–10 min | 15 |
