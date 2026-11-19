# Pre-Flush Checklist

Steps to verify before triggering `flush-lifecycle.yml` (the recommended entry
point) or `full-chain-flush.yml` directly (bypass mode only).
Most are zero-API-call operations — safe to run while quota is exhausted.

---

## 1. Check quota

```bash
curl -sf -H "Authorization: token $SYNC_TOKEN" \
  "https://api.github.com/rate_limit" | python3 -c "
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
pre-flight. Below that it exits 1 and emits a log line that
`rate-limit-rerun.yml` detects — it will re-dispatch automatically after the
reset. The flush itself needs ~1000–1500 to complete without hitting the reserve
floor mid-way.

---

## 2. Run config validators

All must pass with zero errors.

```bash
python3 scripts/validate-gitlab-subgroups.py   config/gitlab-subgroups.yml
python3 scripts/validate-registered-imports.py registered-imports.json
python3 scripts/validate-registered-imports.py registered-imports.json --vouch-check
python3 scripts/validate-cost-profiles.py      config/workflow-cost-profiles.yml
python3 scripts/validate-priority-tiers.py     config/workflow-priority-tiers.yml
python3 scripts/validate-template-config.py
python3 scripts/validate-workflow-guards.py
```

Expected output pattern:
```
config/gitlab-subgroups.yml: 14 subgroups, N repos — ✅ Valid
validate-registered-imports: 157 entry/entries valid (157 unique targets, 157 unique sources)
vouch-check: 0 unvouched upstream org(s)
validate-cost-profiles: 42 profile(s) valid
validate-priority-tiers: N entries valid (tier1=19, tier2=19, tier3=62, tier4=54)
validate-template-config: 7 profile(s) valid, 80 consumer(s) valid
validate-workflow-guards: all checks passed (N workflows, ...)
```

If `--vouch-check` reports unvouched orgs, add them to `.github/VOUCHED-upstreams.td`
after reviewing the upstream for supply-chain risk, then re-run.

---

## 3. Run the test suite

```bash
python3 -m pytest tests/ -v --tb=short
```

All tests must pass. Current baseline: **340 tests**. A lower count means a
test file was accidentally deleted or a conftest broke collection.

---

## 4. ShellCheck modified scripts

```bash
git diff --name-only HEAD~5 -- 'scripts/*.sh' | xargs -r shellcheck --severity=warning
```

SC1091 (not following sourced files) is expected and acceptable across all
scripts that source `includes/budget.sh`, `includes/gh-api.sh`, or
`includes/pr-lifecycle.sh`.

---

## 5. Check for open PRs

Open PRs that are green and mergeable should be merged before the flush.
`pre-flush-prep` Step 2 auto-merges eligible PRs (`mergeable_state == "clean"`),
but GitHub only computes mergeability after CI runs — ensure CI has completed
on all open PRs before triggering.

Dependency-update PRs (`chore(deps): update workflow dependencies`) are safe
to merge without review.

---

## 6. Check vendor/ agnostic state

```bash
bash scripts/check-vendor-agnostic.sh vendor
```

Must exit 0. Violations mean a vendored component has deployment-identity
values hardcoded — fix before flushing.

---

## 7. Verify working tree is clean

```bash
git status --short
git log --oneline -5
```

Uncommitted changes won't be picked up by the flush. Commit or stash everything.

---

## 8. PR lifecycle guard health

The PR lifecycle guard (`pr-lifecycle-guard.yml`) gates OTA Release, Upstream
PRs, and Rebase PRs. Verify `quota-reserve.yml` has run recently and the
reserve floor is healthy (>=1000 remaining after reserve). If quota is tight,
the guard will defer those workflows automatically — no manual action needed.

---

## 9. Vouch system state

```bash
# Confirm VOUCHED.td is current
cat .github/VOUCHED.td

# Confirm no unvouched upstream orgs
python3 scripts/validate-registered-imports.py registered-imports.json --vouch-check
```

If new repos were added to `registered-imports.json` since the last flush,
their upstream orgs may not yet be in `VOUCHED-upstreams.td`. Add them before
flushing so the advisory check stays clean.

---

## 10. Trigger

Once all the above are green:

1. Go to [flush-lifecycle.yml](https://github.com/Interested-Deving-1896/fork-sync-all/actions/workflows/flush-lifecycle.yml)
2. Click **Run workflow**
3. Leave all inputs at defaults for a standard flush

`flush-lifecycle.yml` sets `FLUSH_ACTIVE=true`, holds a sentinel runner slot,
then dispatches `pre-flush-prep` → `full-chain-flush` → `post-flush-prep` in
sequence with quota reservation active throughout.

**Bypass mode** (advanced): trigger `pre-flush-prep.yml` directly if you need
control over its inputs (`skip_merge_prs`, `skip_cleanup`, `quota_wait_min`).
`pre-flush-prep` dispatches `full-chain-flush` automatically at the end of
Step 8. Do not trigger `full-chain-flush` directly unless bypassing both the
lifecycle wrapper and prep intentionally.

---

## Quick reference — pre-flush-prep steps

| Step | Action | Skippable |
|---|---|---|
| Quota pre-flight | Exit 1 + emit rate-limit log if < 500 remaining | No |
| 1 | Cancel stale/queued runs older than `STALE_MIN` | No |
| 2 | Merge green PRs on `main` (mergeable_state == clean) | `skip_merge_prs=true` |
| 3 | Validate all configs (gate — aborts on failure) | No |
| 4 | Clean up merged branch debris across the org | `skip_cleanup=true` |
| 5 | Remove stray template files from consumer repos | `skip_cleanup=true` |
| 6 | Resolve CI failures across configured targets | `skip_resolve_failures=true` |
| 7 | Quota gate — wait up to `QUOTA_WAIT_MIN` for headroom | No |
| 8 | Dispatch `full-chain-flush` | No |

---

## What happens after the flush

`post-flush-prep.yml` fires automatically via `workflow_run: Full Chain Flush`.
It runs four verification checks and posts a summary. If it reports failures,
check the step summary for which repos failed and why before re-flushing.

Template propagation (vouch workflows, SBOM pipeline, PR lifecycle guard) is
delivered to the 80 consumer repos during the flush via `sync-template.sh`.
No manual action is needed — the flush handles it.
