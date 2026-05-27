# AGENTS-IMPROVEMENT-SPEC.md

Working document. Tracks known defects and gaps in fork-sync-all.
Act on items here, then delete them. When all items are resolved, delete this file.

**Not propagated to consumer repos** (excluded in `sync-template.sh`).

---

## Critical — silent wrong behavior

These will silently do the wrong thing when triggered.

### 1. `DRY_RUN` / `REPO_FILTER` inputs are non-functional across most scripts

Every `workflow_dispatch` workflow exposes `dry_run` and `repo_filter` inputs and
passes them as env vars — but the underlying scripts never read them. A dry-run
dispatch will execute real mutations.

Affected scripts (all need the same fix — add `DRY_RUN="${DRY_RUN:-false}"` and
`REPO_FILTER="${REPO_FILTER:-}"` near the top and gate mutations behind them):

| Script | Mutations it will perform on a "dry run" |
|---|---|
| `scripts/sync-to-gitlab.sh` | Pushes branches to GitLab |
| `scripts/sync-from-gitlab.sh` | Pushes branches to GitHub |
| `scripts/mirror-osp-to-gitlab.sh` | Mirrors repos to GitLab |
| `scripts/reconcile-org-refs.sh` | Rewrites file content across all three orgs |
| `scripts/upstream-commits.sh` | Opens real PRs in Interested-Deving-1896 |
| `scripts/upstream-prs.sh` | Opens/merges real PRs |
| `scripts/sync-pieroproietti-forks.sh` | Pushes fork branches |
| `scripts/resolve-failures.sh` | Posts AI comments, closes/reopens PRs |
| `scripts/mirror-releases.sh` | Mirrors releases to OSP/OOC |
| `scripts/mirror-artifacts.sh` | Mirrors artifacts |
| `scripts/mirror-to-osp.sh` | `FORCE` and `REPO_FILTER` inputs ignored |
| `scripts/sync-all-forks.sh` | `FORCE` and `BRANCH_FILTER` inputs ignored |

**Fix pattern:**
```bash
DRY_RUN="${DRY_RUN:-false}"
REPO_FILTER="${REPO_FILTER:-}"

# Gate all mutations:
if [[ "$DRY_RUN" == "true" ]]; then
  echo "[dry-run] would push to ..."
else
  git push ...
fi
```

---

### 2. `workflow_run` triggers reference wrong workflow names

GitHub matches `workflow_run` by the `name:` field in the target workflow file,
not the filename.

| Workflow | References | Actual name in target file | Effect |
|---|---|---|---|
| `update-readmes.yml` L37 | `"sync-from-gitlab"` | `"Sync from GitLab"` | Post-GitLab-sync README update never fires |
| `translate-readmes.yml` L29 | `"sync-from-gitlab"` | `"Sync from GitLab"` | Post-GitLab-sync translation never fires |

**Fix:** Change both references to `"Sync from GitLab"`.

---

### 3. `setup-osp-mirrors.yml` uses wrong secret name

`setup-osp-mirrors.yml` L61 passes `GITLAB_TOKEN: ${{ secrets.GITLAB_TOKEN }}` but
the actual secret is `GITLAB_SYNC_TOKEN`. The "Rewrite org references" step silently
does nothing.

**Fix:** Change `secrets.GITLAB_TOKEN` → `secrets.GITLAB_SYNC_TOKEN`.

---

### 4. `validate-config.yml` env var not read by script

`validate-config.yml` sets `CONFIG_FILE` as an env var but `validate-gitlab-subgroups.py`
reads its path from `sys.argv[1]`, not the environment. The custom config path input
is silently ignored.

**Fix:** Either pass the path as a CLI argument in the workflow step, or update the
script to fall back to `os.environ.get("CONFIG_FILE")`.

---

### 5. `mirror-orgs-full.yml` GHA expression always evaluates to fallback

L58: The pattern `condition && '' || 'fallback'` always evaluates to `'fallback'`
because GHA treats empty string as falsy. The excluded-org logic is broken.

**Fix:** Use `${{ condition && 'value' || 'other-value' }}` with non-empty strings,
or move the logic into the shell step.

---

### 6. `mirror-orgs-watchdog.yml` monitors a non-existent workflow

The watchdog trigger lists `"Mirror OSP → OOC"` — no workflow with that name exists.
The `case` statement maps it to retry `mirror-orgs-full.yml`, which is wrong anyway
(full mirrors `Interested-Deving-1896`, not OSP → OOC).

**Fix:** Remove the dead entry or replace with the correct workflow name.

---

### 7. `sync-eggs-docs-to-book.yml` only stages `chromiumos/`

The copy step mirrors all `docs/*/` subdirectories but the commit step only runs
`git add chromiumos/`. Other subdirectories are copied to disk and never committed.

**Fix:** Change `git add chromiumos/` → `git add .`

---

### 8. `sync-eggs-docs-to-book.yml` and `mirror-orgs-watchdog.yml` call missing script

Both workflows call `bash scripts/write-summary.sh` but neither has a checkout step
that puts `scripts/` at the workspace root (they use `path:` checkouts). The call
always fails with "No such file or directory".

**Fix:** Either add a checkout of fork-sync-all at the workspace root, or inline the
summary logic.

---

### 9. `notify-poller.yml` hardcodes repo path

The resolver trigger URL is hardcoded to `Interested-Deving-1896/fork-sync-all`.
If this workflow is propagated to any consumer repo, it will dispatch against
fork-sync-all instead of the consumer.

**Fix:** Use `${{ github.repository }}` in the URL.

---

### 10. `token-health.yml` hardcodes repo path

Seven `gh issue` calls hardcode `Interested-Deving-1896/fork-sync-all`. Same
problem as above if propagated.

**Fix:** Replace with `${{ github.repository }}`.

---

### 11. `mirror-to-osp.sh` skips repos with `master` default branch

L186: The gate fetches `branches/main` to get HEAD SHA. Repos whose default branch
is `master` (e.g. `penguins-eggs`) get an empty SHA and are silently skipped.

**Fix:** Fetch the default branch name first (`repos/{owner}/{repo}` → `.default_branch`),
then fetch that branch's SHA.

---

### 12. `reconcile-org-refs.sh` pagination cap at 100 repos

Both the REST path and GraphQL fallback fetch at most 100 repos. OSP will exceed
this as the arch repo infrastructure is added.

**Fix:** Add pagination loop (increment `page` / `after` cursor until response < 100).

---

## Bugs — hard crashes

### 13. `sync-to-gitlab.sh` — `REPO_ROOT` unbound variable

`REPO_ROOT` is referenced but never assigned. With `set -uo pipefail` the script
exits immediately on first use.

**Fix:** Assign `REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"` near
the top.

---

### 14. `sync-to-gitlab.sh` — `local` outside function

`local attempt=0` and `local wait=$(...)` appear in the top-level `for` loop body,
not inside any function. Bash treats this as a syntax error in strict mode.

**Fix:** Move the retry logic into a dedicated function.

---

### 15. `sync-btrfs-devel-branches.sh` — 404 on missing branch crashes pipeline

`api_get` uses `--fail`, so a 404 causes curl to exit 22. With `set -uo pipefail`
the whole script aborts on the first missing branch.

**Fix:** Use `--fail-with-body` and check the HTTP status separately, or use
`curl ... || true` and inspect the response body.

---

### 16. `reconcile-org-refs.sh` — `rate_wait` crashes on curl failure

`rate_wait` pipes `curl -sf` directly into `python3`. If curl fails, python3
receives empty stdin and raises `JSONDecodeError`, crashing the script.

**Fix:** Capture curl output, check exit code, then parse.

---

## Missing retry logic

All of these scripts make API calls with no retry on 429/403. A single rate-limit
hit aborts the run silently.

- `scripts/cleanup-branches.sh`
- `scripts/upstream-prs.sh`
- `scripts/sync-btrfs-devel-branches.sh`
- `scripts/mirror-releases.sh` (workflow comment falsely claims it retries)
- `scripts/mirror-orgs.sh` — double-requests on 403 (second request also rate-limited)

**Reference implementation:** `scripts/create-arch-repos.py` `gh_api()` function.

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

`OSP_REPOS` array has 18 repos; `config/gitlab-subgroups.yml` (declared source of
truth) has 31. 13 repos are never synced from upstream.

**Fix:** Replace the hardcoded array with a read from `config/gitlab-subgroups.yml`.

---

### `sync-to-gitlab.sh` hardcoded repo map

Maintains its own `REPOS` array instead of reading `config/gitlab-subgroups.yml`.
Will drift as repos are added.

**Fix:** Same as above — read from the config file.

---

### `config/gitlab-subgroups.yml` name mismatch

Lists `penguins-immutable-framework` under `penguins-eggs_deving` but
`sync-upstream-sources.sh` and `translate-readmes.sh` reference `immutable-linux-framework`.

**Fix:** Align the name in the config or the scripts (check which is the actual repo name).

---

## Scheduling collisions

These pairs fire at the same minute and both make heavy API calls:

| Pair | Slot | Risk |
|---|---|---|
| `reconcile-org-refs.yml` + `sync-registered-imports.yml` | `:50` | 1000–3000 + N calls simultaneously |
| `setup-osp-mirrors.yml` + `upstream-commits.yml` | `:45` | Concurrent writes to OSP repos |
| `mirror-releases.yml` + `mirror-artifacts.yml` | `:00` | Duplicate release mirroring, no concurrency group |

**Fix:** Stagger by 5–10 minutes. Add `concurrency:` groups to `mirror-releases.yml`
and `mirror-artifacts.yml`.

---

## Watchdog gaps

`mirror-orgs-watchdog.yml` does not monitor:
- `mirror-to-osp.yml` (most critical hourly workflow)
- `mirror-releases.yml`
- `mirror-artifacts.yml`
- `sync-btrfs-devel-branches.yml`

**Fix:** Add these to the watchdog trigger list with correct workflow names.

---

## Token expiry (time-sensitive)

From `scripts/token-monitor.sh`:
- `OSP-ORG Mirror Token` expires **2026-06-28** (~32 days from 2026-05-27)
- `sync-mirror-watchdog` expires **2026-07-03** (~37 days from 2026-05-27)

Rotate both before expiry to avoid silent mirror failures.

---

## README timing table is wrong

`README.md` L68 documents incorrect cron times for several workflows:

| Workflow | README says | Actual cron |
|---|---|---|
| `upstream-prs` | `:23` | `:30` |
| `reconcile-org-refs` | `:55` | `:50` |

**Fix:** Update the table to match actual cron expressions.
