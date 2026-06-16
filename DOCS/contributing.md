# Contributing

Conventions for adding workflows, scripts, config entries, and vendor components.

---

## Adding a workflow

1. **Create the workflow file** in `.github/workflows/`

2. **Register in priority tiers** — add an entry to
   `config/workflow-priority-tiers.yml` using the workflow's `name:` field
   (not the filename):
   ```yaml
   - name: "My New Workflow"
     tier: 3   # MEDIUM — adjust based on criticality
   ```
   Tier guide: 1=CRITICAL (never cancelled), 2=HIGH (mirror chain),
   3=MEDIUM (default), 4=LOW (cancelled first under quota pressure)

3. **Register in workflow-sync** — add to `config/workflow-sync.yml`:
   - Under `github_only` if it has no GitLab CI counterpart (most workflows)
   - Under `paired` if it has a matching GitLab CI job

4. **Add a concurrency group** if triggered by `schedule` or `workflow_run`:
   ```yaml
   concurrency:
     group: my-workflow-name
     cancel-in-progress: true
   ```

5. **Add a quota pre-flight** if the workflow makes API calls and runs frequently.
   Use the shared include — do not inline the curl block:
   ```yaml
   - name: Quota pre-flight
     id: quota
     env:
       GH_TOKEN: ${{ secrets.SYNC_TOKEN }}
       MIN_QUOTA: "500"   # adjust to your workflow's actual cost
     run: |
       source scripts/includes/quota-snapshot.sh
       quota_snapshot
   ```
   Gate subsequent steps with `if: steps.quota.outputs.skip == 'false'`.

   The include writes `remaining`, `reset_time`, and `skip` to `GITHUB_OUTPUT`
   and a status line to `GITHUB_STEP_SUMMARY`. It also supports an optional
   `QUOTA_WRITE_VAR: "true"` env var that writes a `QUOTA_SNAPSHOT` repo
   Actions variable — useful for chain entry/exit points so downstream
   workflows can read quota state without an API call via
   `${{ vars.QUOTA_SNAPSHOT }}`. Currently enabled on `pre-flush-prep`,
   `full-chain-flush`, and `post-flush-prep`.

   **Fork note:** `QUOTA_WRITE_VAR` requires the token to have `repo` scope
   (classic PAT) or `variables: write` (fine-grained PAT). If the write fails
   the workflow continues — it logs a warning and the snapshot is simply not
   updated. The `variables: write` permission must also be declared at the
   workflow level:
   ```yaml
   permissions:
     actions: write
     contents: read
     variables: write
   ```
   ```

6. **Validate:**
   ```bash
   python3 scripts/validate-workflow-guards.py
   python3 scripts/validate-priority-tiers.py config/workflow-priority-tiers.yml
   ```

---

## Adding a script

Scripts live in `scripts/`. All logging must go to stderr — never stdout —
because many functions are called inside `$(...)` captures where stdout becomes
the captured value.

```bash
info() { echo "[my-script] $*" >&2; }
warn() { echo "[warn] $*" >&2; }
```

If the script sources `includes/budget.sh` or `includes/gh-api.sh`, add the
shellcheck directive:
```bash
# shellcheck source=includes/budget.sh
source "$(dirname "${BASH_SOURCE[0]}")/includes/budget.sh"
```

Run ShellCheck before committing:
```bash
shellcheck --severity=warning scripts/my-script.sh
```

---

## Adding a config entry

### New repo to GitLab mirror chain

Add to `config/gitlab-subgroups.yml` under the appropriate subgroup:
```yaml
  rust-systems_deving:
    repos:
      - my-new-repo
```

Then validate:
```bash
python3 scripts/validate-gitlab-subgroups.py config/gitlab-subgroups.yml
```

### New repo to upstream sync

Add to `registered-imports.json`:
```json
{
    "source_url": "https://github.com/upstream-org/repo-name",
    "target_name": "repo-name",
    "platform": "github",
    "added": "2026-06-07T00:00:00Z"
}
```

Then validate:
```bash
python3 scripts/validate-registered-imports.py registered-imports.json
```

### New workflow priority tier entry

See "Adding a workflow" above — step 2.

---

## Adding a vendor component

`vendor/` is for third-party components that fork-sync-all hosts or deploys.
It is not for first-party scripts or config.

**Before adding:**
- Confirm the component is genuinely third-party (not a script you wrote)
- Confirm it will be deployed or served by fork-sync-all (not just referenced)

**When adding:**
1. Place under `vendor/<component-name>/`
2. Strip all distro-specific or org-specific hardcoded defaults — see the
   agnostic rule below
3. Add a `README.md` with a "Before the first deploy" section covering all
   required CI variables
4. Run the agnostic check:
   ```bash
   bash scripts/check-vendor-agnostic.sh vendor/<component-name>
   ```

### Agnostic rule

No deployment-identity values may appear as hardcoded fallback defaults in
vendored components. This includes:

- Public URLs: `${VITE_ENDPOINT_URL:-https://api.myorg.com}` ❌
- Org/repo slugs: `${MIRRORLIST_REPO:-MyOrg/my-repo}` ❌
- Arch/repo paths: `${MIRROR_REPO_PATHS:-x86_64/core}` ❌
- Distro names: `${DISTRO:-cachyos}` ❌

Allowed:
- Localhost dev URLs: `${API_URL:-http://localhost:5862}` ✅
- Generic paths: `${MIRRORLIST_PATH:-mirrorlist/mirrorlist}` ✅
- Single-word tokens: `${LOG_LEVEL:-info}` ✅
- UI strings: `${APP_NAME:-Infra Dashboard}` ✅

To suppress a specific line that is intentionally non-agnostic:
```bash
SOME_VAR="${SOME_VAR:-value}"  # check-vendor-agnostic: ignore
```

`enforce-agnostic-vendor.yml` runs automatically on every push/PR touching `vendor/`.

---

## Commit conventions

Follow the existing commit message style:
```
scope: short description

Longer explanation if needed. Focus on why, not what.
```

Common scopes: `fix`, `feat`, `config`, `docs`, `vendor`, `scripts`, `ci`.

---

## Before opening a PR

```bash
# Config validators
python3 scripts/validate-gitlab-subgroups.py config/gitlab-subgroups.yml
python3 scripts/validate-registered-imports.py registered-imports.json
python3 scripts/validate-cost-profiles.py config/workflow-cost-profiles.yml
python3 scripts/validate-priority-tiers.py config/workflow-priority-tiers.yml
python3 scripts/validate-template-config.py
python3 scripts/validate-workflow-guards.py
# ^ also validates workflow-quota-costs.yml entry counts and consistency

# Test suites
python3 -m pytest tests/ -v --tb=short
bash scripts/tests/test-check-readme-render-mobile.sh

# ShellCheck (for any .sh files changed)
git diff --name-only HEAD -- 'scripts/*.sh' | xargs shellcheck --severity=warning

# Vendor check (if vendor/ was touched)
bash scripts/check-vendor-agnostic.sh vendor

# README render check
bash scripts/check-readme-render.sh README.md
```

All must pass before the PR is ready for merge.

---

## Forking this repo

If you fork `fork-sync-all` into your own org, a few things need attention:

### Required secrets

Copy all secrets from the [secrets table in README.md](../README.md#secrets).
At minimum `SYNC_TOKEN` is required — most workflows will skip or fail without it.

### Token scope for `QUOTA_SNAPSHOT`

Three workflows (`pre-flush-prep`, `full-chain-flush`, `post-flush-prep`) write
a `QUOTA_SNAPSHOT` repo Actions variable after their quota pre-flight. This
variable lets downstream chained workflows read quota state without an API call
via `${{ vars.QUOTA_SNAPSHOT }}`.

The write requires:
- **Classic PAT** — `repo` scope is sufficient (already needed by most workflows)
- **Fine-grained PAT** — must include `variables: write` repository permission

If the write fails (wrong scope, token too restricted) the workflow logs a
warning to stderr and continues — nothing breaks, `QUOTA_SNAPSHOT` just won't
be updated for that run. Downstream workflows reading `${{ vars.QUOTA_SNAPSHOT }}`
will see the last successfully written value, or an empty string on first run.

To confirm the variable is being written, check the "Quota pre-flight" step log
for `QUOTA_SNAPSHOT variable updated (HTTP 204)`. If you see
`QUOTA_SNAPSHOT variable write failed (HTTP 403)`, your token needs the
`variables: write` permission and the workflow needs:
```yaml
permissions:
  variables: write
```

### FSA mode detection

Forked instances are detected as `downstream-fork` by `fsa-node-identity.sh`
and skip source-only operations (readmes, badges, fork-sync, templates,
translate) to prevent duplicate work. See [Architecture](architecture.md) for
the full node identity model.

### Config files to update

| File | What to change |
|---|---|
| `config/gitlab-subgroups.yml` | Your GitLab group and subgroup names |
| `registered-imports.json` | Your upstream repos |
| `config/template-consumers.yml` | Your consumer repos |
| `AGENTS.md` | Update org names throughout |
