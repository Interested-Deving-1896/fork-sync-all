# Pre-Flush Checklist

Steps to verify before triggering `pre-flush-prep.yml` or `full-chain-flush.yml`.
Most of these are zero-API-call operations — safe to run while quota is exhausted.

---

## 1. Check quota

```bash
curl -sf -H "Authorization: token $SYNC_TOKEN" \
  "https://api.github.com/rate_limit" | \
  python3 -c "
import sys, json
from datetime import datetime, timezone
d = json.load(sys.stdin)
core = d['resources']['core']
reset = datetime.fromtimestamp(core['reset'], tz=timezone.utc)
now = datetime.now(tz=timezone.utc)
eta = max(0, int((reset - now).total_seconds()))
print(f'Remaining : {core[\"remaining\"]}/{core[\"limit\"]}')
print(f'Reset at  : {reset.strftime(\"%H:%M:%S UTC\")}')
print(f'ETA       : {eta//60}m {eta%60}s')
"
```

`pre-flush-prep` requires at least **500 remaining** to proceed past its quota
pre-flight. Below that it skips entirely. The flush itself needs ~1000–1500 to
complete a full run without hitting the reserve floor mid-way.

---

## 2. Run config validators

All must pass with zero errors. Warnings on `validate-workflow-guards` are
acceptable if they are pre-existing (check `git log` to confirm).

```bash
python3 scripts/validate-gitlab-subgroups.py config/gitlab-subgroups.yml
python3 scripts/validate-registered-imports.py registered-imports.json
python3 scripts/validate-cost-profiles.py config/workflow-cost-profiles.yml
python3 scripts/validate-priority-tiers.py config/workflow-priority-tiers.yml
python3 scripts/validate-template-config.py
python3 scripts/validate-workflow-guards.py
```

Expected output pattern:
```
config/gitlab-subgroups.yml: 12 subgroups, N repos — ✅ Valid
validate-registered-imports: N entry/entries valid
validate-cost-profiles: N profile(s) valid
validate-priority-tiers: N entries valid (tier1=N, tier2=N, tier3=N, tier4=N)
validate-template-config: N profile(s) valid, N consumer(s) valid
validate-workflow-guards: all checks passed (N workflows, ...)
```

---

## 3. Run the test suites

Python validators:
```bash
python3 -m pytest tests/ -v --tb=short
```

Bash `check-readme-render.sh` self-test (checks 13–22, mobile/cross-engine):
```bash
bash scripts/tests/test-check-readme-render-mobile.sh
```

All 213 pytest tests and all 24 shell tests must pass. A failure here means a
script or config change broke something the validators don't catch.

---

## 4. ShellCheck modified scripts

Run against any scripts changed since the last flush:

```bash
git diff --name-only HEAD~5 -- 'scripts/*.sh' | xargs shellcheck --severity=warning
```

Or check the three most commonly modified ones directly:

```bash
shellcheck --severity=warning \
  scripts/import-repo.sh \
  scripts/merge-to-monorepo.sh \
  scripts/check-vendor-agnostic.sh
```

SC1091 (`info` severity, not following sourced files) is expected and acceptable
across all scripts that source `includes/budget.sh` or `includes/gh-api.sh`.

---

## 5. Check for open PRs

Open PRs on `main` that are green and mergeable should be merged before the flush
so the flush runs against the latest state. `pre-flush-prep` Step 2 auto-merges
eligible PRs, but it's cleaner to do it manually if you're already reviewing.

Dependency-update PRs (e.g. `chore(deps): update workflow dependencies`) are
safe to merge without review — they only bump `actions/*` versions.

---

## 6. Check vendor/ agnostic state

```bash
bash scripts/check-vendor-agnostic.sh vendor
```

Must exit 0. Any violations mean a vendored component has deployment-identity
values hardcoded as fallback defaults — fix before flushing so the component
is deployable by anyone.

---

## 7. Verify working tree is clean

```bash
git status --short
git log --oneline -5
```

Uncommitted changes won't be picked up by the flush. Commit or stash everything
before triggering.

---

## 8. Trigger

Once all the above are green:

1. Go to [pre-flush-prep.yml](https://github.com/Interested-Deving-1896/fork-sync-all/actions/workflows/pre-flush-prep.yml)
2. Click **Run workflow**
3. Leave all inputs at defaults for a standard flush
4. Optional inputs:
   - `skip_merge_prs=true` — skip Step 2 if you've already merged PRs manually
   - `skip_cleanup=true` — skip branch/run cleanup if quota is tight
   - `quota_wait_min` — lower from 60 if quota is already healthy

`pre-flush-prep` dispatches `full-chain-flush` automatically at the end of Step 4.
You do not need to trigger `full-chain-flush` directly.

---

## Quick reference — what each step of pre-flush-prep does

| Step | Action | Skippable |
|---|---|---|
| 1 | Cancel stale/queued runs older than `STALE_MIN` | No |
| 2 | Merge green PRs on `main` | `skip_merge_prs=true` |
| 3 | Validate all configs (same as step 2 above) | No |
| 4 | Clean up stale branches and redundant base repos | `skip_cleanup=true` |
| 5 | Dispatch `full-chain-flush` | No |
