# Runbooks

Operational procedures for common and emergency situations.

---

## Quota exhaustion

**Symptoms:** workflows fail with 403, `gh api` calls return empty, `validate-config`
skips with "quota too low".

**Check current state:**
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

**Recovery:**
1. Wait for the reset (up to 1 hour). The reset time is shown above.
2. While waiting, use the time productively — all local operations (config
   validation, ShellCheck, pytest, file edits) work without quota.
3. After reset, trigger `pre-flush-prep.yml` to clear the queue and restart
   the mirror chain cleanly.

**Prevention:** `quota-reserve.yml` cancels low-priority runs at < 1000 remaining.
If exhaustion is recurring, check `config/workflow-quota-costs.yml` for
unexpectedly expensive workflows (the `cost_high` and `min_quota` fields) and
consider raising `MIN_QUOTA` thresholds. `config/workflow-cost-profiles.yml`
has the detailed per-call breakdown if you need to trace where calls are going.

---

## Queue pile-up

**Symptoms:** many workflows stuck in "queued" state, runners appear busy but
nothing is completing.

**Check:**
```bash
# Via GitHub CLI (requires quota)
gh run list --repo Interested-Deving-1896/fork-sync-all --status queued --limit 50
```

**Recovery:**
1. Trigger `queue-manager.yml` manually — it deduplicates and evicts runs
   queued > 25 minutes.
2. If the queue is severely backed up, trigger `pre-flush-prep.yml` with
   `skip_merge_prs=true` and `skip_cleanup=true` — Step 1 aggressively
   clears stale runs before dispatching the flush.
3. As a last resort, trigger `critical-deploy.yml` — it performs an aggressive
   queue clear and dispatches with priority.

---

## Token expiry

**Symptoms:** `token-health.yml` opens an issue labelled `token-monitor`, or
workflows fail with 401.

**Check expiry:**
```bash
bash scripts/token-monitor.sh
```

**Rotate a token:**
1. Generate a new PAT at https://github.com/settings/tokens
2. Go to `rotate-token.yml` → **Run workflow**
3. Select the secret name from the dropdown
4. Paste the new token value
5. Leave `validate` checked
6. Update the expiry date in `AGENTS.md` token rotation table

For OSP org secrets (`MIRROR_TOKEN`, `ORG_MIRROR_OSP_TO_OOC`), see the
[Token Rotation](../AGENTS.md#token-rotation) section in AGENTS.md — these
require a separate PAT with `admin:org` on `OpenOS-Project-OSP`.

---

## Mirror chain broken

**Symptoms:** repos in OSP or OOC are behind I-D-1896 by more than one cycle,
or GitLab mirrors show stale commits.

**Diagnose:**
```bash
# Check GitLab sync status (requires quota)
gh workflow run check-gitlab-sync.yml --repo Interested-Deving-1896/fork-sync-all
```

**Recovery by leg:**

| Broken leg | Fix |
|---|---|
| I-D-1896 → OSP | Trigger `mirror-to-osp.yml` manually |
| OSP → OOC | Trigger `mirror-osp-to-ooc.yaml` manually |
| OSP → GitLab | Trigger `mirror-osp-to-gitlab.yml` manually |
| GitLab → I-D-1896 | Trigger `sync-from-gitlab.yml` manually |

For a full chain reset, trigger `full-chain-flush.yml` directly (or via
`pre-flush-prep.yml` for a clean pre-flight first).

---

## Config validation failure

**Symptoms:** `validate-config.yml` fails on push, blocking the flush.

**Run locally to see the error:**
```bash
python3 scripts/validate-gitlab-subgroups.py config/gitlab-subgroups.yml
python3 scripts/validate-registered-imports.py registered-imports.json
python3 scripts/validate-cost-profiles.py config/workflow-cost-profiles.yml
python3 scripts/validate-priority-tiers.py config/workflow-priority-tiers.yml
python3 scripts/validate-template-config.py
python3 scripts/validate-workflow-guards.py
```

Common causes:
- Duplicate repo name in `gitlab-subgroups.yml`
- Duplicate `source_url` or `target_name` in `registered-imports.json`
- Workflow added to `.github/workflows/` but not registered in
  `workflow-priority-tiers.yml` or `workflow-sync.yml`
- Duplicate name in `workflow-priority-tiers.yml`

---

## Vendor component agnostic check failure

**Symptoms:** `enforce-agnostic-vendor.yml` fails on a PR touching `vendor/`.

**Run locally:**
```bash
bash scripts/check-vendor-agnostic.sh vendor
```

The output shows the exact file, line, and category of violation. Fix by:
- Removing the hardcoded fallback value (set to empty string)
- Moving the value to a CI variable / repo var
- Adding `# check-vendor-agnostic: ignore` if the value is genuinely
  deployment-agnostic (rare — document why)

---

## README render failure

**Symptoms:** `validate-readme-render.yml` fails on a PR.

**Run locally:**
```bash
bash scripts/check-readme-render.sh README.md
# Also run the self-test to verify the checker itself is working:
bash scripts/tests/test-check-readme-render-mobile.sh
```

Common causes: unclosed fences, leaked log lines, bare `[text]` links without
URLs, raw angle brackets, broken tables, missing H1.

---

## OTA delivery failure

**Symptoms:** `ota-release.yml` fails for one or more forks, or a fork's
`ota-self-update.yml` fails.

**For a single fork:**
1. Check the fork's `ota-self-update.yml` run logs for the specific error
2. Common causes: fork has diverged significantly, `pinned_sha` is stale,
   or the fork's `.ota/config.yml` has an invalid field
3. To reset: update `pinned_sha` in the fork's `.ota/config.yml` to the
   current upstream HEAD SHA, then re-trigger `ota-self-update.yml`

**To skip a fork temporarily:**
Set `disabled: true` in its `config/ota-registry.yml` entry.

**To re-deliver to all forks:**
Push a new semver tag to `fork-sync-all` — `ota-release.yml` triggers automatically.

---

## Incident response checklist

For any production incident affecting the mirror chain:

1. **Check quota** — if exhausted, wait for reset before doing anything else
2. **Check queue** — trigger `queue-manager.yml` to clear pile-ups
3. **Identify the broken leg** — use `check-gitlab-sync.yml` and manual inspection
4. **Fix the specific leg** — trigger the relevant mirror workflow directly
5. **Validate config** — run all validators locally before triggering a flush
6. **Run pre-flush-prep** — let it clean up and restart the chain
7. **Monitor** — watch the first few workflow runs after recovery for secondary failures
