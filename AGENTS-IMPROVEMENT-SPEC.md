# AGENTS-IMPROVEMENT-SPEC.md

Working document. Tracks known defects and gaps in fork-sync-all.
Act on items here, then delete them. When all items are resolved, delete this file.

**Not propagated to consumer repos** (excluded in `sync-template.sh`).

---

## Critical — silent wrong behavior

### 1. `DRY_RUN` / `REPO_FILTER` inputs

~~Fixed~~ — verified 2026-05-27. All 12 affected scripts correctly declare
`DRY_RUN="${DRY_RUN:-false}"` and `REPO_FILTER="${REPO_FILTER:-}"` and gate
mutations behind them. The spec entry was stale.

---

### 2. `workflow_run` triggers reference wrong workflow names

~~Fixed~~ — `translate-readmes.yml` referenced `"Sync Docs to Book"` but the
actual workflow name is `"Sync penguins-eggs docs to penguins-eggs-book"`.
Corrected 2026-05-27. All other `workflow_run` references verified clean.

---

### 3. `setup-osp-mirrors.yml` uses wrong secret name

~~Verified not present~~ — `setup-osp-mirrors.yml` does not pass `GITLAB_TOKEN` at
all. `reconcile-org-refs.sh` reads `GITLAB_TOKEN="${GITLAB_TOKEN:-}"` and skips the
GitLab pass non-fatally if absent. No fix needed.

---

### 4. `validate-config.yml` env var not read by script

~~Verified fixed~~ — `validate-config.yml` L57 passes `$CONFIG_FILE` as a CLI
argument (`python3 scripts/validate-gitlab-subgroups.py "$CONFIG_FILE"`), which
`validate-gitlab-subgroups.py` reads via `sys.argv[1]`. Already correct.

---

### 5. `mirror-orgs-full.yml` GHA expression always evaluates to fallback

~~Verified not broken~~ — the expressions use `&& 'SKIP' || 'value'` where `'SKIP'`
is a non-empty truthy string, so the ternary works correctly. The broken pattern
(`&& '' || 'fallback'`) is not present here.

---

### 6. `mirror-orgs-watchdog.yml` monitors a non-existent workflow

~~Verified fixed~~ — watchdog covers all 5 workflows with correct names:
`"Mirror Interested-Deving-1896 → OSP"`, `"Mirror Orgs"`, `"Mirror OSP → GitLab"`,
`"Mirror Releases"`, `"Mirror Artifacts"`. Dead entry and wrong `case` mapping
are gone.

---

### 7. `sync-eggs-docs-to-book.yml` only stages `chromiumos/`

~~Verified fixed~~ — uses `git add .` already. All `docs/*/` subdirectories are
staged correctly.

---

### 8. `sync-eggs-docs-to-book.yml` and `mirror-orgs-watchdog.yml` call missing script

~~Verified fixed~~ — `sync-eggs-docs-to-book.yml` has an unpathed `actions/checkout@v6`
as its first step, putting `scripts/` at the workspace root. `mirror-orgs-watchdog.yml`
also has a checkout step.

---

### 9. `notify-poller.yml` hardcodes repo path

~~Verified fixed~~ — uses `${{ github.repository }}` throughout. Already correct.

---

### 10. `token-health.yml` hardcodes repo path

~~Verified fixed~~ — uses `${{ github.repository }}` throughout. Already correct.

---

### 11. `mirror-to-osp.sh` skips repos with `master` default branch

~~Fixed 2026-05-27~~ — `default_branch` is now extracted from the already-fetched
`upstream_info` response and used in place of the hardcoded `main` for both the
CI gate SHA fetch and the open-PRs check.

---

### 12. `reconcile-org-refs.sh` pagination cap at 100 repos

~~Verified fixed~~ — both REST (page loop) and GraphQL (cursor loop) paths are
fully paginated already.

---

## Bugs — hard crashes

### 13. `sync-to-gitlab.sh` — `REPO_ROOT` unbound variable

~~Verified fixed~~ — `REPO_ROOT` is assigned at line 35 via `dirname "${BASH_SOURCE[0]}"`.

---

### 14. `sync-to-gitlab.sh` — `local` outside function

~~Verified fixed~~ — retry logic is inside functions; no top-level `local` declarations.

---

### 15. `sync-btrfs-devel-branches.sh` — 404 on missing branch crashes pipeline

~~Fixed 2026-05-27~~ — `api_get` now uses `curl -w "%{http_code}"` with retry on
403/429 and returns empty string (not exit 1) on 404. `get_branch_sha` uses
`|| true` to suppress non-zero exits.

---

### 16. `reconcile-org-refs.sh` — `rate_wait` crashes on curl failure

~~Verified fixed~~ — `rate_wait` uses `|| true` on the curl call and `|| echo "100"`
fallback on the python3 parse, so a curl failure degrades gracefully.

---

## Missing retry logic

~~Fixed 2026-05-27~~ — all scripts now have retry on 403/429:

- `scripts/cleanup-branches.sh` — `gh_get`/`gh_delete` rewritten with retry
- `scripts/upstream-prs.sh` — `api_get` rewritten with retry
- `scripts/sync-btrfs-devel-branches.sh` — `api_get` rewritten with retry
- `scripts/mirror-releases.sh` — already had retry (spec was stale)
- `scripts/mirror-orgs.sh` — already had retry (spec was stale)

---

## Stale / diverged feature branches

These branches should be closed — all their content is already in `main` or
their unique commits are harmful:

| Branch | Status | Action |
|---|---|---|
| `feat/absorb-dangling-work` | Ancestor of main, 0 unique commits | Delete |
| `feat/absorb-org-mirror` | 12 commits behind main, all merged | Delete |
| `feat/reconcile-gitlab-pass` | Reverts deliberate design decision | Delete |
| `feat/validate-gitlab-subgroups` | Downgrades checkout action, removes inputs | Delete |
| `feat/workflow-dispatch-inputs` | Removes large swaths of workflows | Delete |
| `feat/sync-btrfs-devel-branches` | Token var rename conflicts with main | Merge or delete |

---

## Config drift

### `sync-upstream-sources.sh` hardcoded repo list is stale

~~Verified fixed~~ — reads from `config/gitlab-subgroups.yml` via a Python inline
script with a hardcoded fallback array. The fallback is only used if the config
parse fails.

---

### `sync-to-gitlab.sh` hardcoded repo map

~~Verified fixed~~ — reads from `config/gitlab-subgroups.yml` via `REPO_ROOT`.

---

### `config/gitlab-subgroups.yml` name mismatch (`penguins-immutable-framework`)

**Still open.** Verify which is the actual repo name in `Interested-Deving-1896`
and align the config and any script references accordingly.

---

## Scheduling collisions

~~Verified fixed~~ — all three pairs are already staggered:

| Pair | Actual slots |
|---|---|
| `reconcile-org-refs.yml` + `sync-registered-imports.yml` | Daily `05:50` vs hourly `:55` — no collision |
| `setup-osp-mirrors.yml` + `upstream-commits.yml` | `:45` vs `:47` — 2 min gap |
| `mirror-releases.yml` + `mirror-artifacts.yml` | `:00` vs `:10` — 10 min gap, both have `concurrency:` |

---

## Watchdog gaps

~~Verified fixed~~ — watchdog covers all 5 critical workflows: `Mirror Interested-Deving-1896 → OSP`,
`Mirror Orgs`, `Mirror OSP → GitLab`, `Mirror Releases`, `Mirror Artifacts`.

---

## Token expiry (time-sensitive)

From `scripts/token-monitor.sh`:
- `OSP-ORG Mirror Token` expires **2026-06-28** (~32 days from 2026-05-27)
- `sync-mirror-watchdog` expires **2026-07-03** (~37 days from 2026-05-27)

Rotate both before expiry to avoid silent mirror failures.

---

## README timing table is wrong

~~Fixed 2026-05-27~~ — `upstream-prs` corrected from `:23` → `:30`. `reconcile-org-refs`
is listed as "Manual / on push" in the README which is accurate — the daily cron
(`50 5 * * *`) is an implementation detail not worth surfacing in the table.
