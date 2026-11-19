# OTA Reconcile

OTA Reconcile is a hybrid fallback and drift-detection layer that sits between
the push-based template sync system and the pull-based OTA delivery system.

It runs on a weekly schedule (and on demand) and autonomously selects the
appropriate recovery path for each repo at runtime based on observed state.

---

## Problem statement

Template sync (`sync-template.sh`) is push-based and continuous, but has three
failure modes that leave repos silently out of date:

1. **Quota exhaustion** — propagation stops early; repos processed after the
   cutoff never receive the update. The checkpoint resumes on the next push, but
   if no push occurs the gap persists indefinitely.

2. **Silent drift** — a file in a consumer repo was manually edited, a sync
   failed with a non-fatal error, or a new file was added to the template after
   the last push that touched that consumer's path filter. The repo is behind
   but no alarm fires.

3. **No version record** — mirror-chain repos have no machine-readable record of
   which fork-sync-all commit they last received. There is no way to answer
   "is this repo current?" without diffing every file.

OTA Reconcile addresses all three without replacing or duplicating template sync.

---

## Architecture

### Three paths, one runtime selector

`ota-reconcile.sh` evaluates each consumer repo and selects one of three paths:

| Path | Name | When selected | What it does |
|------|------|---------------|--------------|
| A | **Version stamp** | Repo is current (no drift detected) | Writes/updates `.ota/version` with the current FSA commit SHA and timestamp. Zero file changes, no PR. |
| B | **Drift reconcile** | Drift detected, template sync healthy | Runs `ota-payload-build.sh --full` scoped to template-manifest-owned files, opens a PR with the delta. |
| C | **Quota fallback** | Template sync failed/incomplete for this repo | Same as B, but triggered by detecting the repo's `.ota/version` SHA is behind the last successful FSA push and no in-flight sync PR exists. |

The selector runs all detection checks upfront and picks the lowest-cost path
that addresses the observed state. A repo that is current takes path A (one API
call to write the version stamp). A repo with drift takes path B or C depending
on whether the drift is due to a quota failure.

### Detection checks (run per repo, in order)

```
1. Read .ota/version from target repo (raw.githubusercontent — no quota cost)
   → missing or empty: repo has never been stamped → path B (full reconcile)

2. Compare .ota/version SHA against current FSA HEAD SHA
   → matches: repo is current → path A (stamp only, update timestamp)
   → behind: proceed to check 3

3. Check for an open OTA/reconcile PR against this repo (gh_get /pulls)
   → open PR exists: already in-flight → skip (avoid duplicate PRs)
   → no open PR: proceed to check 4

4. Check sync-template.sh checkpoint file residue via repo Actions variable
   OTA_SYNC_INCOMPLETE (set by sync-template.sh on quota-exhausted exit)
   → variable present and value == 'true': quota failure caused the gap → path C
   → variable absent or false: drift from another cause → path B

5. Run ota-payload-build.sh --full (dry-run) to confirm actual file delta
   → zero files changed: stamp only (path A) — version was behind but files match
   → files changed: open PR (path B or C, label differs)
```

Check 1 uses `raw.githubusercontent.com` (no quota). Checks 2–4 use at most
3 REST calls per repo. Check 5 (payload build) clones two repos — only reached
when drift is confirmed.

### Version stamp format

`.ota/version` is a plain YAML file written to every consumer on each
reconcile pass:

```yaml
# Managed by fork-sync-all ota-reconcile. Do not edit manually.
fsa_sha: abc1234def5678...   # FSA HEAD SHA at time of last successful sync
fsa_ref: main
stamped_at: 2026-06-17T12:00:00Z
reconcile_path: A            # A | B | C — which path was taken
template_sync_sha: abc1234   # SHA of last template sync (from sync-template.sh)
```

`sync-template.sh` also writes this file on each successful consumer sync
(path A stamp, no PR needed) so the record is maintained even between
reconcile runs.

### Scope boundary

OTA Reconcile only touches files that `template-manifest.yml` declares as
owned by template sync for the consumer's profile. It does **not** touch:

- Files outside the profile's include set
- `.ota/config.yml` (managed by the repo owner)
- `README.md`, `registered-imports.json`, `dep-graph/` (always excluded)
- Workflow files that the consumer has `disclaim:`-ed in `.ota/config.yml`

This is the same boundary enforced by `ota-payload-build.sh`. Reconcile
reuses that script directly — it does not implement its own diffing.

---

## Configuration

### `ota-blocklist.yml` — new field

```yaml
# Profiles eligible for OTA reconcile (drift detection + fallback).
# These are mirror-chain profiles normally excluded from OTA delivery.
# Reconcile is additive — it does not replace template sync for these repos.
reconcile_eligible_profiles:
  - full
  - mirror
  - infra-core
  - standalone
```

All four profiles are eligible by default. A repo can opt out of reconcile
by setting `reconcile: false` in its `.ota/config.yml`.

### `.ota/config.yml` — new fields (consumer-side)

```yaml
# Opt out of OTA reconcile entirely (still receives template sync normally)
reconcile: false

# Override which path reconcile is allowed to take for this repo
# Useful for repos where auto-PRs are undesirable
reconcile_max_path: A   # A | B | C (default: C — all paths allowed)
```

### `OTA_SYNC_INCOMPLETE` Actions variable (set by sync-template.sh)

`sync-template.sh` sets this variable on the consumer repo when it exits
due to quota exhaustion before processing that repo:

- `true` — this repo was in the queue when quota ran out
- absent / `false` — repo was processed (successfully or with a non-quota error)

OTA Reconcile reads this variable (check 4) to distinguish path B from path C,
then clears it after opening the recovery PR.

---

## Workflow

`ota-reconcile.yml` runs weekly (Wednesdays 03:17 UTC) and on manual dispatch.

**Inputs (manual dispatch):**
- `dry_run` — report what would happen without writing anything or opening PRs
- `repo_filter` — process only repos matching this name substring
- `force_path` — override runtime path selection (`A`, `B`, or `C`)
- `profile_filter` — limit to repos with this template profile

**Outputs (job summary):**

```
OTA Reconcile — v1.1.0 — 2026-06-17

Repos processed:  48
  Path A (stamp): 41
  Path B (drift): 5
  Path C (quota): 2
  Skipped:        0
  Failed:         0

Path B PRs opened:
  Interested-Deving-1896/some-repo  → ota/reconcile-v1.1.0
  ...

Path C PRs opened:
  Interested-Deving-1896/other-repo → ota/reconcile-v1.1.0 [quota-recovery]
  ...
```

---

## Interaction with existing systems

| System | Interaction |
|--------|-------------|
| `sync-template.sh` | Reconcile is downstream — it detects what sync missed, never races with it. Sync writes `.ota/version` on success; reconcile reads it. |
| `ota-deliver.sh` | Orthogonal — deliver targets opted-in independent forks; reconcile targets mirror-chain consumers. No overlap in registry. |
| `ota-self-update.yml` | Orthogonal — self-update runs in the fork itself (pull-based); reconcile runs in fork-sync-all (push-based). |
| `quota-reserve.yml` | Reconcile is tier 4 (LOW) — cancelled first when quota is low. This is intentional: reconcile is a safety net, not a critical path. |
| `queue-manager.yml` | Standard concurrency group `ota-reconcile` — at most one run at a time. |

---

## Exit codes (`ota-reconcile.sh`)

| Code | Meaning |
|------|---------|
| 0 | All repos processed; no failures |
| 1 | One or more repos failed (payload build error, PR creation error) |
| 2 | Quota exhausted mid-run; partial completion (resume on next run) |
