# AGENTS.md

Conventions, patterns, and known pitfalls for AI agents working in this repo.

---

## Repository overview

`fork-sync-all` is the control plane for the `Interested-Deving-1896` GitHub org.
It mirrors repos into `OpenOS-Project-OSP` (GitHub) and then to `openos-project` (GitLab),
manages READMEs across ~49 OSP-bound repos, syncs upstream forks, and runs org-wide
maintenance workflows.

Key config files:
- `config/gitlab-subgroups.yml` — single source of truth for GitLab subgroup placement
- `registered-imports.json` — upstream repos to keep in sync
- `scripts/` — all automation scripts
- `.github/workflows/` — GitHub Actions workflows

Key directories:
- `vendor/` — third-party components hosted/deployed by fork-sync-all (e.g. `infra-dashboard`).
  Everything in `scripts/` is first-party automation. Do not move scripts into `vendor/`.

---

## GitHub API quota

Both `GH_TOKEN` and `SYNC_TOKEN` belong to the same user (ID 202036334) and share
the same 5000 req/hr REST bucket. Treat them as one pool.

- `raw.githubusercontent.com` fetches do **not** count against the quota
- GraphQL counts as 1 call regardless of how many repos are queried
- The quota pre-flight in workflows uses `MIN_QUOTA` (typically 1000–1500) to skip
  runs when the bucket is too low; `quota-monitor.sh` retries after reset

When quota is at 0, avoid any `gh api`, `curl .../api.github.com/...`, or `gh_get`
calls. Check reset time with:
```bash
curl -sf -H "Authorization: token $SYNC_TOKEN" \
  "https://api.github.com/rate_limit" | jq '{remaining, reset: (.resources.core.reset | todate)}'
```

---

## Script conventions

### All logging helpers must write to stderr

Every script defines some combination of `info()`, `warn()`, `dry()`, and `log()`.
All **must** use `>&2`:

```bash
info() { echo "[script-name] $*" >&2; }
warn() { echo "[warn] $*" >&2; }
dry()  { echo "[dry-run] $*" >&2; }
log()  { echo "[$(date -u '+%H:%M:%S')] $*" >&2; }
```

**Why this matters:** Several functions are called inside `$(...)` subshell captures
where their stdout becomes the captured value (e.g. README content, repo lists,
API responses). Any logging call without `>&2` inside such a function will corrupt
the captured data.

This applies to `includes/gh-api.sh` too — `merge_upstream()` status messages
must go to stderr since callers may capture its output via `result=$(merge_upstream ...)`.

Known functions called inside `$(...)` captures — never emit to stdout inside these:
- `rewrite_readme()` in `update-readmes.sh`
- `fill_missing_sections()` in `update-readmes.sh`
- `build_readme()` in `create-readmes.sh`
- `generate_*()` functions in `update-readmes.sh`
- `merge_upstream()` in `scripts/includes/gh-api.sh`

### YAML parsing

Always use `yaml.safe_load` — never hand-rolled regex/indent parsers:

```python
import yaml
with open(config_path) as f:
    config = yaml.safe_load(f)
subgroups = config.get("subgroups", {}) or {}
```

This applies to `gitlab-subgroups.yml` parsing in all scripts.

### `includes/` scripts

`scripts/includes/budget.sh`, `scripts/includes/gh-api.sh`, and
`scripts/includes/quota-instrument.sh` are sourced by many scripts and workflows.
Changes there have broad impact.

- `budget.sh` — provides `budget_init`, `budget_check`, `budget_report`,
  `osp_priority_repos`, and `workflow_min_quota`. The latter reads per-workflow
  `min_quota` from `config/workflow-quota-costs.yml`.
- `gh-api.sh` — provides `gh_api`, `gh_get`, `gh_api_graphql`, `merge_upstream`,
  `get_default_sha`. All status messages use `>&2`. Guard against double-sourcing
  is in place (`_GH_API_LOADED`). `gh_get URL` is a convenience GET wrapper around
  `gh_api` with full retry and reset-aware backoff — the canonical implementation
  that individual scripts should migrate to (see consolidation note below).

### `gh_get` / `gh_api` consolidation (complete)

All scripts now source `includes/gh-api.sh` for `gh_get`. The three tiers
that existed during migration have been fully consolidated:

| Tier | Scripts | Status |
|---|---|---|
| Full retry (canonical) | `check-osp-ci.sh`, `cleanup-branches.sh` | ✅ migrated |
| No retry, fail-fast | `create-readmes.sh`, `inject-badges.sh`, `pre-flush-prep.sh`, `readme-wizard.sh`, `rebase-prs.sh`, `sync-template.sh`, `update-readmes.sh` | ✅ migrated |
| No retry, silent fail | `rerun-after-rate-limit.sh`, `scan-rate-limit-failures.sh` | ✅ migrated (added `\|\| echo '{}'` fallbacks on capture sites) |

All new scripts should source `includes/gh-api.sh` and use `gh_get` directly.
Do **not** define a local `gh_get()` in any new script.
- `quota-instrument.sh` — provides `qi_begin` / `qi_end` for measuring REST quota
  consumption per workflow run. Wire into the main job step of any workflow you want
  to instrument. Writes a structured HTML comment to `GITHUB_STEP_SUMMARY` that
  `update-quota-costs.yml` parses weekly to compute observed p50/p95 values.

### REST → GraphQL conversion

Prefer GraphQL over paginated REST for any loop that fetches the same data for
multiple repos. GraphQL counts as **1 REST call** regardless of how many repos
are queried.

**Standard pattern for org repo lists:**
```bash
result=$(curl -sf \
  -H "Authorization: token ${GH_TOKEN}" \
  -H "Content-Type: application/json" \
  "${GH_API}/graphql" \
  -d "{\"query\":\"{ organization(login: \\\"${ORG}\\\") { repositories(first: 100) { nodes { name } pageInfo { hasNextPage endCursor } } } }\"}" \
  2>/dev/null || echo "{}")
echo "$result" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for n in d.get('data',{}).get('organization',{}).get('repositories',{}).get('nodes',[]):
    print(n['name'])
" 2>/dev/null
```

**Prefetch pattern for per-repo metadata (existence, pushedAt, README):**
Batch all repos into a single GraphQL call using aliases, populate an associative
array, then read from the cache in the loop — zero REST calls per repo:
```bash
declare -A _REPO_EXISTS=()
# ... build aliases, fire one GraphQL call, populate _REPO_EXISTS ...
# In the loop:
[[ -z "${_REPO_EXISTS[$repo]:-}" ]] && continue  # skip non-existent repos
```

See `sync-registered-imports.sh` (`prefetch_repo_metadata`),
`mirror-releases.sh` (`prefetch_upstream_existence`), and
`inject-badges.sh` (`list_gh_repos` + `_README_CACHE`) for reference implementations.

**What cannot be converted to GraphQL:**
- `check-runs` and `statuses` endpoints — not exposed in GraphQL
- `actions/workflows` and `actions/secrets` — not in GraphQL
- Write operations (create repo, push file, cancel run) — REST only

### Tree fetches

Use `?recursive=1` on the git trees endpoint to get all file paths in one call,
then check membership with `grep -qxF` before fetching individual files:

```bash
tree_json=$(gh_get "${GH_API}/repos/${owner}/${repo}/git/trees/HEAD?recursive=1")
tree_paths=$(echo "$tree_json" | jq -r '.tree[] | select(.type=="blob") | .path')
echo "$tree_paths" | grep -qxF "package.json" && # file exists, fetch it
```

Never probe file existence with per-file `/contents/` calls in a loop.

### YAML-safe shell in `run:` blocks

GitHub Actions `run:` blocks are YAML block scalars. The YAML parser processes
the file before the shell runner sees it, so certain shell constructs break
parsing even though they would be valid bash.

**Patterns that break YAML — never use these inside `run:` blocks:**

| Pattern | Why it breaks | Fix |
|---|---|---|
| `VAR="` with newline before closing `"` | Opens an unclosed YAML flow scalar | Use `printf` or write to a temp file |
| `python3 -c "` with newline before closing `"` | Same — unclosed flow scalar | Collapse to a single-line `-c` invocation |
| `---` on its own line | YAML document separator | Use `----` or `printf '\xe2\x80\x94'` for em dash |
| Heredoc end-marker that is a bare YAML keyword (`YAML`, `EOF`, `END`) at column 0 | Parsed as a bare mapping key | Rename to `OTA_CONFIG_EOF`, `PYEOF`, etc. — anything not a YAML keyword |
| Multi-line `git commit -m "..."` | Unclosed flow scalar | Use `$'subject\n\nbody'` ANSI-C quoting or chained `-m` flags |

**Safe alternatives:**

```bash
# Multi-line python: collapse to one line
repos=$(python3 -c "import yaml; d=yaml.safe_load(open('config/x.yml')); print(' '.join(d.get('repos',[])))")

# Multi-line variable: use printf into a temp file
printf 'line1\nline2\n' > /tmp/body.txt

# Multi-line commit message: ANSI-C quoting
git commit -m $'subject\n\nbody line 1\nbody line 2'

# Or chained -m flags (each becomes a paragraph)
git commit -m "subject" -m "body paragraph"

# Heredoc end-marker: use a non-YAML-keyword name
cat > file.yml << 'CONFIG_EOF'
...
CONFIG_EOF
```

**The validator catches these:** `python3 scripts/validate-workflow-guards.py` runs
a YAML parse check across all 75 workflow files. Run it after editing any workflow.
The full-suite parse check is also embedded in `validate-config.yml`.

---

## Workflow patterns

### Queue and quota management

Three workflows protect the system from quota exhaustion cascades and runner starvation:

| Workflow | Schedule | Purpose |
|---|---|---|
| `queue-manager.yml` | Every 30 min + after `rate-limit-rerun` | Deduplicates queued runs (keeps newest per workflow) and evicts runs queued > 25 min |
| `quota-reserve.yml` | Every 30 min + after `rate-limit-rerun` | Cancels low-priority queued runs when quota drops below 1000. Uses per-workflow `min_quota` from `config/workflow-quota-costs.yml` for cost-aware cancellation. |
| `critical-deploy.yml` | Manual only | Fast-lane: commit + push → aggressive queue clear → priority dispatch |

**Priority tiers** — single source of truth in `config/workflow-priority-tiers.yml`:
- Tier 1 CRITICAL — never cancelled (token rotation, queue/reserve management, config validation)
- Tier 2 HIGH — mirror chain, sync operations
- Tier 3 MEDIUM — READMEs, CI checks (default for unknown workflows)
- Tier 4 LOW — translation, dep graph, maintenance (cancelled first)

When adding a new workflow, add it to **both**:
1. `config/workflow-priority-tiers.yml` — by workflow `name:` field (not filename). Both `queue-manager.sh` and `quota-reserve.sh` load tiers from this file at runtime — no script edits needed.
2. `config/workflow-sync.yml` — under `github_only` (most workflows) or `paired` (if it has a GitLab CI counterpart). `validate-workflow-guards.py` warns on any workflow file not listed in either section.

Run `python3 scripts/validate-workflow-guards.py` after adding any workflow to confirm zero warnings.

**`dispatch-and-wait.sh` exit codes:**
- `0` — workflow completed successfully
- `1` — workflow failed or timed out
- `2` — workflow was cancelled (by queue-manager or manually) — retriable, not a real failure

`full-chain-flush.yml` and `critical-deploy.sh` both handle exit 2 with a warning rather than aborting.

### Concurrency groups

All workflows triggered by `schedule` or `workflow_run` must have a concurrency group
to prevent queue pile-ups:

```yaml
concurrency:
  group: workflow-name
  cancel-in-progress: true
```

### `workflow_run` triggers

Each workflow should have at most **one** `workflow_run` upstream trigger.
Multiple triggers cause fan-out: N completions × M downstream workflows = queue explosion.

Every name in `workflow_run.workflows:` must exactly match the `name:` field of a
workflow file that actually exists in `.github/workflows/`. A phantom name causes the
trigger to fire on every push but the job fails immediately — GitHub cannot resolve
the upstream workflow. `validate-workflow-guards.py` (Check 5) catches this automatically.

### Quota pre-flight

All hourly/daily/frequent workflows include a quota pre-flight step before doing
any API work. The step sets `skip=true` when remaining < `MIN_QUOTA` and subsequent
steps check `if: steps.quota.outputs.skip == 'false'`.

### Quota cost registry

`config/workflow-quota-costs.yml` is the single source of truth for per-workflow
REST call cost estimates. It drives:
- `quota-reserve.sh` — cost-aware cancellation (`min_quota` per workflow)
- `budget.sh` `workflow_min_quota()` — pre-flight helper for self-skipping
- `DOCS/quota-costs.md` — rendered documentation in mdBook

**Phase 1** values are code-audit estimates (`basis: code-audit`).
**Phase 2** (`update-quota-costs.yml`, weekly) replaces them with observed p50/p95
values (`basis: observed`) once ≥5 run samples exist per workflow.

When adding a new workflow that makes significant REST calls, add it to
`config/workflow-quota-costs.yml` with estimated `min_quota`, `cost_low`,
`cost_mid`, `cost_high`, and `basis: code-audit`. Wire `qi_begin`/`qi_end`
from `scripts/includes/quota-instrument.sh` into its main job step so Phase 2
can measure it automatically.

**Instrumented workflows** (Phase 2 active):
- Sync All Forks
- Inject Built-with-Ona Badges
- Reconcile Org References
- Cleanup Stale Branches
- Check OSP-Bound CI Status
- Check Shell Tools CI
- Sync Registered Imports
- Sync Shell Tools
- Sync UAA Vendor
- Mirror Interested-Deving-1896 → OSP
- Pre-Mirror CI Gate
- Verify Mirror Integrity
- Post-Flush Verification
- Pipeline Telemetry
- Translate Docs
- Integrate Shell Tools
- Onboard Repo

### Path filters + required status checks (gate job pattern)

When a workflow uses path filters to skip jobs on irrelevant changes, required
status checks will block PRs indefinitely if the filtered jobs never run.
Fix this with a gate job that always runs and reflects the filtered outcomes:

```yaml
jobs:
  changes:
    name: Detect changes
    runs-on: ubuntu-latest
    outputs:
      shell: ${{ steps.filter.outputs.shell }}
    steps:
      - uses: actions/checkout@v4
      - uses: dorny/paths-filter@v3
        id: filter
        with:
          filters: |
            shell:
              - '**/*.sh'

  lint:
    name: ShellCheck
    needs: changes
    if: needs.changes.outputs.shell == 'true'
    runs-on: ubuntu-latest
    steps: [...]

  # Set THIS as the required status check — not the individual jobs above.
  ci-required:
    name: CI Required
    runs-on: ubuntu-latest
    needs: [lint]
    if: always()
    steps:
      - name: Check results
        run: |
          if echo "${{ join(needs.*.result, ' ') }}" | grep -qw "failure"; then
            exit 1
          fi
```

**Branch protection must require `CI Required`** (the gate job name), not the
individual filtered job names. If the individual names are listed as required
checks, PRs that skip those jobs will be permanently blocked.

Applied in: `btrfs-dwarfs-framework/.github/workflows/ci.yaml`

---

## Autonomous-fallback mode

Consumer repos that receive the `infra-core` or `upstream-sync` profile get a
bundle of operational workflows (rate-limit rerun, CI resolver, queue manager,
quota reserve, notify-poller, branch cleanup) as autonomous fallbacks.

**Managed mode** (default): fork-sync-all is present and handles all of these
centrally. The bundled workflows detect this and skip themselves.

**Autonomous mode**: if a consumer repo is forked independently without
fork-sync-all alongside it, the bundled workflows activate and self-manage,
scoped to the repo's own owner.

### Mode detection (`scripts/includes/fsa-mode.sh`)

Three-tier hybrid check, evaluated in order:

| Check | Mechanism | Cost |
|---|---|---|
| B | `FSA_MANAGED` repo variable (`vars.FSA_MANAGED == 'true'`) | 0 API calls |
| A | GET `/repos/{owner}/fork-sync-all` — 200 = managed | 1 API call |
| C | Token owner's fork-sync-all existence (tiebreaker) | 2 API calls |

`sync-template.sh` sets `FSA_MANAGED=true` as a repo Actions variable on every
successful consumer sync via `PUT /repos/{owner}/{repo}/actions/variables/FSA_MANAGED`.

### Adding the guard to a workflow

```bash
- name: Check FSA mode
  id: fsa
  env:
    GH_TOKEN: ${{ secrets.SYNC_TOKEN }}
    FSA_MANAGED: ${{ vars.FSA_MANAGED }}
    REPO_OWNER: ${{ github.repository_owner }}
  run: |
    source scripts/includes/fsa-mode.sh
    if fsa_is_managed; then
      echo "managed=true" >> "$GITHUB_OUTPUT"
      echo "Managed by fork-sync-all — skipping."
    else
      echo "managed=false" >> "$GITHUB_OUTPUT"
    fi

# Then on work steps:
- name: Do work
  if: steps.fsa.outputs.managed == 'false'
```

For workflows **without a checkout** (e.g. `notify-poller.yml`), inline the
three-tier check directly in the step's `run:` block rather than sourcing
`fsa-mode.sh`. See `notify-poller.yml` for the canonical inline implementation.
The inline version replicates checks B → A → C using `curl` and `python3`.

### Scope narrowing in autonomous mode

Workflows that are org-wide in managed mode narrow their scope in autonomous mode:

| Workflow | Managed scope | Autonomous scope |
|---|---|---|
| `resolve-failures.yml` | I-D-1896 (OSP-bound) + OSP + OOC | `github.repository_owner` only |
| `cleanup-branches.yml` | I-D-1896 + OSP + OOC | `github.repository_owner` only |
| `queue-manager.yml` | `github.repository` (already scoped) | same |
| `quota-reserve.yml` | `github.repository` (already scoped) | same |
| `rate-limit-rerun.yml` | `github.repository_owner/name` | same |

### Template manifest — source:dest remap syntax

Include entries in `config/template-manifest.yml` support a `source:dest` remap:

```yaml
include:
  - assets/docs-scaffold/SUMMARY.md:DOCS/SUMMARY.md   # read from assets/, write to DOCS/
  - scripts/write-summary.sh                           # plain entry: source == dest
```

`sync-template.sh` splits on the first `:` — the left side is the path relative
to the template root (read), the right side is the path written into the target
repo. Plain entries (no `:`) write to the same path.

**Scaffold-only behaviour**: entries whose source starts with `assets/docs-scaffold/`
are skipped if the destination file already exists in the target repo. This
prevents overwriting a consumer's existing `DOCS/` content on subsequent syncs.

### Devcontainer template propagation

`devcontainer.template.json` and `automations.template.yaml` are propagated to
consumer repos via source:dest remaps in `config/template-manifest.yml`. Both
are scaffold-only — skipped if the destination already exists in the consumer.

```yaml
include:
  - .devcontainer/devcontainer.template.json:.devcontainer/devcontainer.json
  - .devcontainer/automations.template.yaml:.ona/automations.yaml
```

These entries are present in the `infra-core`, `upstream-sync`, `standalone`,
and `shell-tools` profiles. The `.devcontainer/` directory is otherwise excluded
from template sync (it contains fork-sync-all-specific config that consumers
should not receive).

**Template divergence rule**: `devcontainer.template.json` and the live
`.devcontainer/devcontainer.json` must stay in sync. When updating either:
- Pin `headroom-ai` to a specific version in both files
- Keep `--no-ccr-inject-tool` in the headroom proxy start command in both
  `automations.template.yaml` and `.ona/automations.yaml`
- Run `python3 scripts/devcontainer-validate.py` to catch divergences

### Devcontainer feature — `git-platform-clis`

`.devcontainer/features/git-platform-clis/` is a devcontainer feature that
installs CLIs for all major git hosting platforms.

**Installed by default:** `gh` (GitHub CLI), `glab` (GitLab CLI), `tea` (Gitea CLI)

**Optional via feature options:** `hub` (legacy GitHub CLI), `bb` (Bitbucket CLI),
`forgejo-cli` (Forgejo/Gitea v1.21+ API client) — all `false` by default.

Referenced in `devcontainer.json` and `devcontainer.template.json` by local path.
When published to GHCR via `devcontainer-sdk.yml publish` mode, consumers can
reference it by URI: `ghcr.io/Interested-Deving-1896/fork-sync-all/git-platform-clis:1`

**The feature has not yet been published to GHCR.** Until a `publish` run
completes, only local path references work. Run `devcontainer-sdk.yml` with
`mode: publish` to push it.

### Devcontainer SDK workflow (`devcontainer-sdk.yml`)

Three modes, selectable via `workflow_dispatch`:

| Mode | Trigger | What it does |
|---|---|---|
| `validate` | Auto on push to `.devcontainer/` | Runs `devcontainer-validate.py` — checks JSON validity, template divergence, feature schema |
| `build` | Manual | Builds the devcontainer image and pushes to GHCR as an OCI artifact |
| `publish` | Manual | Publishes features from `.devcontainer/features/` to GHCR so consumers can reference by URI |

Supporting scripts: `scripts/devcontainer-validate.py`, `scripts/devcontainer-build.sh`,
`scripts/devcontainer-publish-features.sh`, `scripts/devcontainer-base-image.py`.

### Verify Fork Integrity

`verify-fork-integrity.yml` / `scripts/verify-fork-integrity.sh` — single-repo
equivalent of `verify-mirror-integrity.yml`. Compares this repo's default-branch
HEAD against its upstream (fork parent or `upstream_override`).

Upstream resolution order:
1. `inputs.upstream_override` (workflow dispatch input)
2. `.ota/config.yml` `upstream_override` field
3. GitHub fork parent API field (auto-detected)

Returns `status`: `identical` | `ahead` | `behind` | `diverged`. Set
`BLOCK_ON_DRIFT=true` to exit 1 on `behind` or `diverged`.

### OTA system — autonomous upstream resolution

Both `ota-self-update.yml` and `ota-opt-in.yml` now resolve their upstream
dynamically rather than hardcoding `Interested-Deving-1896/fork-sync-all`:

| Priority | Source |
|---|---|
| 1 | `upstream_override` in `.ota/config.yml` |
| 2 | GitHub fork parent API (`/repos/{owner}/{repo}` → `parent.full_name`) |
| 3 | Fallback: `Interested-Deving-1896/fork-sync-all` |

`ota-opt-in.yml` writes the resolved upstream into `.ota/config.yml` as
`upstream_override` so subsequent `ota-self-update.yml` runs use Check 1
(zero API calls for resolution).

`ota-opt-in.yml` opens the registration issue against the resolved upstream
repo (not hardcoded fork-sync-all). The upstream repo must have an
`ota-registration` label and a `config/ota-registry.yml` for the issue to
be actionable.

### `resolve-failures.sh` — EXCLUDED_REPOS convention

`EXCLUDED_REPOS` in `scripts/resolve-failures.sh` is intentionally empty. The
resolver appends `[skip ci]` to every fix commit, which prevents CI re-triggers
in all standard repos. Only add a repo to `EXCLUDED_REPOS` when `[skip ci]` is
genuinely insufficient — for example, a repo with a push hook that ignores
`[skip ci]` and would cause an infinite fix→trigger→fail→fix loop.

### README & repo description management — autonomous single-repo mode

In autonomous mode (fork-sync-all not present), README workflows scope to the
current repo only:

- `update-readmes.sh`: set `SINGLE_REPO=<repo-name>` to bypass the org fetch
  and process exactly one repo. `update-readmes.yml` sets this automatically
  via the FSA mode check.
- `translate-readmes.sh`: `SCOPE=single` sets `REPOS` to the current repo name
  (extracted from `GITHUB_REPOSITORY`). `translate-readmes.yml` sets this
  automatically in autonomous mode.

### `resolve-failures.sh` — rate-limit rerun

Before sending a failed run to the AI fixer, `resolve-failures.sh` calls
`rerun_if_rate_limited()`, which checks job logs for rate-limit signal patterns
and re-triggers via `POST /repos/{owner}/{repo}/actions/runs/{id}/rerun-failed-jobs`.
This covers all three orgs (I-D-1896 OSP-bound, OSP, OOC). The loop guard
checks for `"rate_limit_rerun": "true"` in the step summary — a second
rate-limit failure is logged but not re-triggered again.

---

## Template sync profiles

`config/template-consumers.yml` controls which repos receive automatic file
updates from `sync-template.yml`. Each consumer has a `profile` that determines
what gets injected.

### Profile assignments

| Profile | What it injects | Who should use it |
|---|---|---|
| `full` | Everything — all workflows, scripts, config | `fork-sync-all` only |
| `mirror` | Mirror/sync workflows + infra tooling | **Nobody** — deprecated, do not assign |
| `infra-core` | PR automation, token rotation, token health, README render validation + full autonomous-fallback suite (rate-limit rerun, CI resolver, queue/quota management, branch cleanup, PR rebase, dep updates, OTA self-management, README & repo description management, mdBook deploy/translate, fork integrity check) — dormant when fork-sync-all is present | Consumer repos that are targets of the mirror chain |
| `standalone` | PR automation + token rotation only | External project forks (KDE Invent, etc.) |
| `upstream-sync` | `infra-core` contents + upstream sync workflow and script | Repos that track upstream projects via a registry file |

### Critical rule

**Never assign `mirror` profile to consumer repos.** The `mirror` profile injects
the full fork-sync-all mirror/sync suite (60+ workflow files, 100+ scripts) into
repos that are *targets* of the mirror chain, not operators of it. This causes
template pollution — files that have no purpose in the target repo and clutter
its `.github/workflows/` and `scripts/` directories.

### Template pollution cleanup

If a repo has been polluted by the `mirror` profile:

1. Check which files don't belong:
```bash
for f in .github/workflows/*.yml; do
  grep -q "SYNC_TOKEN\|openos-project\|mirror-to-osp\|registered-imports" "$f" \
    && echo "POLLUTION: $(basename $f)" \
    || echo "native:    $(basename $f)"
done
```

2. Remove them with `git rm --cached` and commit:
```bash
git rm --cached .github/workflows/add-mirror-repo.yml  # etc.
git commit -m "chore: remove fork-sync-all template pollution"
```

3. Delete the untracked files from disk:
```bash
git status --short | grep "^??" | awk '{print $2}' | xargs rm -f
```

4. Trigger `cleanup-pollution.yml` (workflow_dispatch) to clean remaining
   consumer repos automatically.

### Repos cleaned of mirror pollution (2026-06-06)

- `KPort` — 74 files removed
- `btrfs-dwarfs-framework` — 133 files removed
- All other `infra-core` consumers — cleaned via `cleanup-pollution.yml`

### Queue pile-up pattern

Workflows that trigger on `.github/workflows/**` (e.g. `validate-config`,
`update-workflow-triggers-doc`) must have `concurrency: cancel-in-progress: true`
to prevent stacking. Without it, rapid pushes create a queue of identical runs
that consume quota on every reset, causing a deadlock where the queue can't
drain because quota is always 0.

```yaml
concurrency:
  group: workflow-name-${{ github.ref }}
  cancel-in-progress: true
```

---

## Brandable backend

`config/brand.yml` allows fork-sync-all to be adopted as a white-label subsystem.
When `brand.enabled=true`, `sync-template.sh` substitutes `{{FSA_*}}` tokens in
propagated file content with the consumer's own identity values.

**Default state: `brand.enabled=false`** — no behaviour change until a consumer
explicitly opts in by setting `enabled: true` in their own `config/brand.yml`.

### Substitution tokens

| Token | Field | Example |
|---|---|---|
| `{{FSA_NAME}}` | `brand.name` | `fork-sync-all` |
| `{{FSA_SLUG}}` | `brand.slug` | `fsa` |
| `{{FSA_ORG}}` | `brand.org` | `Interested-Deving-1896` |
| `{{FSA_REPO}}` | `brand.repo` | `fork-sync-all` |
| `{{FSA_DESCRIPTION}}` | `brand.description` | one-line description |
| `{{FSA_SUPPORT_URL}}` | `brand.support_url` | support/docs URL |

### Applying brand substitution

`scripts/apply-brand.py` reads `config/brand.yml` and rewrites tokens in a
target file. Called by `sync-template.sh` after writing each propagated file
when `brand.enabled=true`.

```bash
python3 scripts/apply-brand.py path/to/file.yml
```

### `skin.files` overrides

The `skin.files` list in `config/brand.yml` maps source files to destination
paths in consumer repos, applied after the profile include list. Entries are
scaffold-only by default (`scaffold_only: true`). Set `scaffold_only: false`
to always overwrite.

---

## Git subtree / submodule / umbrella scaffold

`config/subtree-manifest.yml` declares three relationship types between this
repo and external repos. `scripts/manage-subtrees.sh` implements all operations.
`manage-subtrees.yml` runs weekly (Sunday 01:00 UTC) and on manual dispatch.

### Relationship types

| Type | Mechanism | Best for |
|---|---|---|
| `subtree` | `git subtree add/pull` — remote history merged under a prefix dir, no `.gitmodules` | Vendored upstream code you modify locally |
| `submodule` | Standard git submodule — pinned SHA, `.gitmodules` entry, pointer not copy | External deps you consume but don't modify |
| `umbrella` | This repo as super-repo — aggregates child repos as submodules under `umbrella.prefix/` | Monorepo-style development across org repos |

### `manage-subtrees.sh` commands

```bash
bash scripts/manage-subtrees.sh sync          # pull all subtrees + update all submodules
bash scripts/manage-subtrees.sh add <name>    # add a new subtree/submodule from manifest
bash scripts/manage-subtrees.sh status        # show drift vs upstream for all entries
bash scripts/manage-subtrees.sh umbrella-init # initialise umbrella children as submodules
```

### Adding a new entry

Add to the appropriate list in `config/subtree-manifest.yml`, then run
`manage-subtrees.sh add <name>`. Do not run `git subtree add` or
`git submodule add` manually — the script handles squash flags, shallow
clones, and `.gitmodules` consistency.

### Nested submodule policy

`nested.recurse=false` by default. Enable only when a submodule itself has
submodules you need. `nested.max_depth=2` prevents runaway recursion.

---

## OSP-bound repo list

The canonical list of ~49 repos that are mirrored to GitLab lives in
`config/gitlab-subgroups.yml`. Parse it with `yaml.safe_load` — do not hardcode
repo names anywhere else.

To get the list in bash:
```bash
python3 -c "
import yaml
data = yaml.safe_load(open('config/gitlab-subgroups.yml'))
for sg in data.get('subgroups', {}).values():
    for repo in (sg.get('repos') or []):
        print(repo)
"
```

### GitLab subgroup IDs

Parent group: `openos-project` on GitLab (`gitlab.com/openos-project`)

| Subgroup slug | GitLab ID |
|---|---|
| `git-management_deving` | 130516820 |
| `penguins-eggs_deving` | 130516402 |
| `immutable-filesystem_deving` | 130516465 |
| `linux-kernel_filesystem_deving` | 130516188 |
| `incus_deving` | 130516536 |
| `taubyte_deving` | 133909500 |
| `neon-deving` | 130739746 |
| `ops` | 130734009 |
| `yaml-tooling_deving` | 133909501 |
| `cachyos_deving` | 133909503 |
| `ai-agents_deving` | 133909504 |
| `rust-systems_deving` | 133954601 |

All IDs are authoritative — sourced from `config/gitlab-subgroups.yml`. Do not hardcode them elsewhere.

---

## README & Repo Description Management

### AI marker format

```
<!-- AI:start:section-name -->
content
<!-- AI:end:section-name -->
```

Eight AI-owned sections: `what-it-does`, `architecture`, `ci`, `mirror-chain`,
`contributors`, `origins`, `resources`, `license`.

Human-owned sections (`Install`, `Usage`, `Configuration`, `License`) never get
AI markers — they get placeholder HTML comments on first creation.

### Three modes in `update-readmes.sh`

- `rewrite` — no AI markers present → build full template from scratch
- `fill` — some markers present but missing sections → inject missing ones
- `update` — all markers present → regenerate AI section content

### `check-readme-render.sh`

Run this against any README before committing. It catches: leaked log lines,
unclosed fences, unclosed AI markers, empty sections, missing H1, broken tables,
bare `[text]` links, raw angle brackets.

```bash
bash scripts/check-readme-render.sh path/to/README.md
```

### Per-file repo descriptions (`generate-repo-descriptions.sh`)

Generates a one-line AI description for every file in a repo and commits the
results to `DESCRIPTIONS.md`. Uses GitHub Models (`gpt-4o-mini` by default —
high volume, short outputs, no frontier reasoning needed).

Inspired by `ioncakephper/repo-description` — reimplemented using `llm.sh`
(GitHub Models) instead of Groq + Node.js.

**Output format** (`DESCRIPTIONS.md`):
```markdown
# File Descriptions
<!-- AI:generated -->

| File | Description |
|---|---|
| `scripts/sync-forks.sh` | Syncs all upstream forks via the GitHub merge-upstream API |
| `config/gitlab-subgroups.yml` | Maps OSP-bound repos to their GitLab subgroup placement |
```

**Workflow:** `generate-repo-descriptions.yml` — runs weekly (Sunday 03:30 UTC),
dispatches manually with `target_repo`, `model`, `max_files`, `file_filter` inputs.
`SKIP_EXISTING=true` by default so incremental runs only describe new files.

**Key env vars:**
- `TARGET_REPO` — repo to describe (defaults to `fork-sync-all` itself on schedule)
- `MAX_FILES` — cap per run (default: 200) to control quota consumption
- `MODEL` — override model (default: `openai/gpt-4o-mini`)

### Repo settings management (`manage-repo-settings.sh`)

Declarative repo settings drift detection and enforcement across all OSP-bound
repos. Reads `config/repo-settings.yml` and either reports drift (check mode)
or enforces declared state (apply mode) via the GitHub REST API.

Inspired by `andrewthetechie/gha-repo-manager` — reimplemented as a shell script
using `gh-api.sh` + `budget.sh` infrastructure.

**Settings file:** `config/repo-settings.yml` — `defaults` block applies to all
repos, `overrides` block provides per-repo overrides, `skip` list excludes repos.

**Supported fields:** `description`, `homepage`, `has_issues`, `has_projects`,
`has_wiki`, `has_discussions`, `allow_squash_merge`, `allow_merge_commit`,
`allow_rebase_merge`, `allow_auto_merge`, `delete_branch_on_merge`,
`squash_merge_commit_title`, `squash_merge_commit_message`, `topics`,
`vulnerability_alerts`.

**Workflow:** `manage-repo-settings.yml` — runs weekly in check mode (Monday
04:30 UTC). Apply mode is manual-only (`workflow_dispatch` with `mode: apply`)
to prevent accidental bulk changes.

**API cost:** 1 REST call per repo in check mode. 1–3 REST calls per drifted
repo in apply mode (PATCH settings + PUT topics + PUT/DELETE vulnerability alerts).

---

## GitLab CI variables

These must be set as masked CI/CD variables in the `openos-project/fork-sync-all` GitLab project settings (not GitHub secrets):

| Variable | Maps to | Used by | Notes |
|---|---|---|---|
| `GITLAB_TOKEN` | `GITLAB_TOKEN` GitHub secret | Most GitLab CI jobs | api + read_repository + write_repository scope |
| `WORKFLOW_SECRET` | `SYNC_TOKEN` GitHub secret | sync-forks, notify-poller, resolve-failures, rate-limit-rerun, token-health, cleanup-branches | GitHub PAT with repo + workflow + admin:org scopes |
| `GH_SYNC_TOKEN` | `GH_SYNC_TOKEN` GitHub secret | sync-from-gitlab | GitHub PAT with repo + workflow scopes |
| `GITLAB_MAINTENANCE_TOKEN` | — | maintain:storage | Inherited from openos-project group variable; api scope on GitLab |

---

## Headroom proxy

A context compression proxy runs on port 8787 (started automatically via
`.ona/automations.yaml`). To use it with Claude:

```bash
ANTHROPIC_BASE_URL=http://localhost:8787 claude
# or
headroom wrap claude
```

Check savings: `headroom stats`

---

## Token rotation

### Tracked tokens

The "PAT name" column is the display name shown at [github.com/settings/tokens](https://github.com/settings/tokens) (classic).

| Secret | PAT name | Scope | Platform / Org | Expiry | Used by | Rotate via |
|---|---|---|---|---|---|---|
| `SYNC_TOKEN` | `fork-sync-all SYNC_TOKEN` | admin:org, admin:org_hook, admin:repo_hook, audit_log, delete:packages, delete_repo, gist, notifications, project, repo, workflow, write:packages | GitHub / I-D-1896 | 2026-09-02 | Most workflows | [rotate-token.yml] |
| `GH_SYNC_TOKEN` | `sync-mirror-watchdog` | admin:org, admin:org_hook, admin:public_key, admin:repo_hook, audit_log, gist, notifications, project, repo, workflow, write:discussion, write:packages | GitHub / I-D-1896 | 2026-09-03 | mirror workflows | [rotate-token.yml] |
| `OSP_ADMIN_TOKEN` | `OSP_ADMIN_TOKEN` | admin:org | GitHub / OpenOS-Project-OSP | 2026-09-03 | rotate-token.yml (OSP org secret rotation) | [rotate-token.yml] |
| `MIRROR_TOKEN` | `OSP-ORG Mirror Token` | admin:enterprise, admin:gpg_key, admin:org, admin:org_hook, admin:public_key, admin:repo_hook, admin:ssh_signing_key, project, repo, workflow | GitHub / OpenOS-Project-OSP | 2026-09-01 | mirror workflows | [rotate-token.yml] |
| `ORG_MIRROR_OSP_TO_OOC` | `OSP-ORG Mirror Token` | (same PAT as `MIRROR_TOKEN`) | GitHub / OpenOS-Project-OSP | 2026-09-01 | mirror-osp-to-ooc.yaml | [rotate-token.yml] |
| `ADD_MIRROR_REPO_SYNC` | `fork-sync-all-ona` | admin:repo_hook, read:org, repo, workflow | GitHub / I-D-1896 | 2026-08-13 ⚠️ | add-mirror-repo.yml | [rotate-token.yml] |
| `GITLAB_SYNC_TOKEN` | `fork-sync-all-sync` | api, read_repository, write_repository | GitLab / openos-project | 2027-05-13 | sync-to-gitlab.yml, mirror-osp-to-gitlab.yml, sync-from-gitlab.yml | [rotate-token.yml] |
| `GITLAB_TOKEN` | `Ona-Env-Secret` | api | GitLab / openos-project | 2027-05-17 | Ona dev environment (injected as GITLAB_TOKEN env var); also used by gl-storage-scan, sync-to-gitlab-variant, cleanup-pollution, reconcile-org-refs | [rotate-token.yml] |
| `BITBUCKET_TOKEN` | n/a (opt-in) | Bitbucket API | Bitbucket | unknown | sync-registered-imports.yml, clone-org.yml, import-repo.yml — skipped if unset | [rotate-token.yml] |
| `GITEA_TOKEN` | n/a (opt-in) | Gitea API | Gitea instance | unknown | sync-registered-imports.yml, clone-org.yml, import-repo.yml — skipped if unset | [rotate-token.yml] |

| `ACTIVITYSMITH_API_KEY` | n/a (external service) | ActivitySmith API | ActivitySmith | unknown | full-chain-flush.yml (live activity tracking) — optional, skipped if unset | manual |
| `ACTIVITYSMITH_CHANNELS` | n/a (external service) | ActivitySmith channel IDs | ActivitySmith | n/a | full-chain-flush.yml — optional, skipped if unset | manual |
| `ANTHROPIC_API_KEY` | n/a (external service) | Anthropic API | Anthropic | n/a | validate-config.yml (AgentShield scan) — optional, skipped if unset | manual |

[rotate-token.yml]: https://github.com/Interested-Deving-1896/fork-sync-all/actions/workflows/rotate-token.yml
[OSP org secrets]: https://github.com/organizations/OpenOS-Project-OSP/settings/secrets/actions

### How to rotate a repo secret (SYNC_TOKEN, GH_SYNC_TOKEN, etc.)

1. Generate a new PAT at https://github.com/settings/tokens
2. Go to [rotate-token.yml] → **Run workflow**
3. Select the secret name from the dropdown
4. Paste the new token value into the `token_value` field
5. Leave `validate` checked — it confirms the token works before finishing
6. After the run completes, update the expiry date in this table

### How to rotate an OSP org secret (ORG_MIRROR_OSP_TO_OOC, MIRROR_TOKEN)

OSP org secrets live in `OpenOS-Project-OSP` and require a token with
`admin:org` on that org. `SYNC_TOKEN` only covers `Interested-Deving-1896`.

The `rotate-token.yml` workflow resolves the OSP token automatically in
this priority order:

#### Option 1 — GitHub App (preferred, permanent)

A GitHub App installation token never expires and has fine-grained permissions.

**One-time setup:**
1. Create a GitHub App at https://github.com/settings/apps/new
   - Name: `fork-sync-all-osp-rotator` (or similar)
   - Permissions: **Organization secrets → Read and write**
   - Uncheck everything else
2. Install the App on `OpenOS-Project-OSP` org
3. Note the **App ID** (shown on the app settings page)
4. Generate a **private key** (PEM format) from the app settings page
5. Add two repo secrets to `Interested-Deving-1896/fork-sync-all`:
   - `OSP_APP_ID` — the numeric App ID
   - `OSP_APP_PRIVATE_KEY` — the full PEM contents (including header/footer)
6. Run [rotate-token.yml] — it will use the App automatically

#### Option 2 — Dedicated PAT (bridge until App is set up)

1. Generate a new PAT at https://github.com/settings/tokens with:
   - `admin:org` scope
   - Authorized for `OpenOS-Project-OSP` org (SSO authorize if required)
2. Add it as repo secret `OSP_ADMIN_TOKEN` in `Interested-Deving-1896/fork-sync-all`
3. Run [rotate-token.yml] — it will use `OSP_ADMIN_TOKEN` automatically

#### Option 3 — Manual fallback

If neither `OSP_APP_*` nor `OSP_ADMIN_TOKEN` is set, the workflow prints
the exact error and the two options above. You can also update manually:

1. Generate a new PAT with `admin:org` on `OpenOS-Project-OSP`
2. Go to [OSP org secrets] and update the secret value directly
3. Update the expiry date in `scripts/token-monitor.sh` (`OSP_ORG_SECRETS` array)
   and in the table above

⚠️ **Upcoming rotations (as of 2026-06-08):**
- `ADD_MIRROR_REPO_SYNC` — expires 2026-08-13 (66 days). `token-health.yml` will open an issue around 2026-06-29.
- `MIRROR_TOKEN` / `ORG_MIRROR_OSP_TO_OOC` — expire 2026-09-01 (85 days). Alert ~2026-07-17.
- `SYNC_TOKEN` — expires 2026-09-02 (86 days). Alert ~2026-07-18.
- `GH_SYNC_TOKEN` / `OSP_ADMIN_TOKEN` — expire 2026-09-03 (87 days). Alert ~2026-07-19.

### Automated monitoring

`token-health.yml` runs weekly (Monday 09:00 UTC) and warns at 45 days before expiry.
When a token needs attention it opens a GitHub issue labelled `token-monitor`.
Run it manually at any time to get a current status report.

---

## vendor/ conventions

### Agnostic-by-default rule

Everything imported into `vendor/` must be deployment-agnostic. No distro names,
org-specific URLs, org/repo slugs, or arch/repo paths may appear as hardcoded
fallback values in shell `${VAR:-...}`, YAML `|| '...'`, or TypeScript `?? '...'`
expressions. All deployment-identity values belong in CI variables or repo vars
set per deployment.

### Enforcement

`scripts/check-vendor-agnostic.sh` scans a vendor directory and exits 1 on violations:

```bash
bash scripts/check-vendor-agnostic.sh vendor/infra-dashboard   # specific component
bash scripts/check-vendor-agnostic.sh vendor                   # all of vendor/
```

`enforce-agnostic-vendor.yml` runs this automatically on every push/PR touching `vendor/`.

To suppress a specific line that is intentionally non-agnostic:
```bash
SOME_VAR="${SOME_VAR:-specific-value}"  # check-vendor-agnostic: ignore
```

### What the checker flags vs. allows

Flagged (deployment-identity):
- Public URLs as fallbacks: `${VITE_ENDPOINT_URL:-https://api.myorg.com}`
- Org/repo slugs: `${MIRRORLIST_REPO:-MyOrg/my-repo}`
- Arch/repo paths: `${MIRROR_REPO_PATHS:-x86_64/core,x86_64/extra}`
- Bare distro names: `${DISTRO:-cachyos}`, `${DISTRO:-ubuntu}`

Allowed (generic defaults):
- Localhost dev URLs: `${API_URL:-http://localhost:5862}`
- Generic relative paths: `${MIRRORLIST_PATH:-mirrorlist/mirrorlist}`
- Single-word tokens: `${LOG_LEVEL:-info}`, `${ENV:-production}`
- UI strings: `${APP_NAME:-Infra Dashboard}`

---

## Workflow integrations

### import-repo → immediate sync

When `ongoing_sync=true`, `import-repo.sh` writes to `registered-imports.json`
and then immediately dispatches `sync-registered-imports.yml` with
`repo_filter=<name>` and `force_sync=true`. This avoids the up-to-6h wait for
the scheduled run to pick up the new entry.

If the dispatch fails (quota, permissions), it falls back gracefully — the entry
is still registered and will sync on the next scheduled run.

### merge-to-monorepo → OSP mirror chain

`merge-to-monorepo.yml` has a `mirror_monorepo` boolean input (default: false).
When set, it dispatches `add-mirror-repo.yml` for the newly created monorepo after
a successful merge, entering it into the standard OSP mirror chain automatically.

---

## Known pitfalls

- **`fill_missing_sections` case statement** — must handle all 8 AI sections.
  If you add a new section to `ALL_AI_SECTIONS`, add it to the `case` in
  `fill_missing_sections`, `rewrite_readme`, and the `update` mode loop.

- **`sync-registered-imports.sh` does not create repos** — `ensure_gh_repo()`
  handles creation now, but the target repo must be reachable via the GitHub API.
  New entries in `registered-imports.json` will auto-create the repo on first run.

- **GitLab mirror chain** — `I-D-1896 → OpenOS-Project-OSP (GitHub) → openos-project (GitLab)`.
  Adding a repo to `gitlab-subgroups.yml` is required for GitLab mirroring.
  Adding to `registered-imports.json` is required for upstream sync.
  Both are independent — a repo can be in one without the other.

- **`_inter_repo_sleep` in `update-readmes.sh`** — quota-aware pacing.
  No delay when quota > 2000; scales to 30s when < 500. The cached
  `_quota_remaining` variable is decremented by 10 per repo to trigger
  re-checks before actually hitting the threshold.
