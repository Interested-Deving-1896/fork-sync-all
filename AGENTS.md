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

`scripts/includes/budget.sh` and `scripts/includes/gh-api.sh` are sourced by many
scripts. Changes there have broad impact.

- `budget.sh` — provides `budget_init`, `budget_check`, `budget_report`, and
  `osp_priority_repos`. The latter parses `gitlab-subgroups.yml` with `yaml.safe_load`.
- `gh-api.sh` — provides `gh_api`, `gh_api_graphql`, `merge_upstream`,
  `get_default_sha`. All status messages use `>&2`. Guard against double-sourcing
  is in place (`_GH_API_LOADED`).

### Tree fetches

Use `?recursive=1` on the git trees endpoint to get all file paths in one call,
then check membership with `grep -qxF` before fetching individual files:

```bash
tree_json=$(gh_get "${GH_API}/repos/${owner}/${repo}/git/trees/HEAD?recursive=1")
tree_paths=$(echo "$tree_json" | jq -r '.tree[] | select(.type=="blob") | .path')
echo "$tree_paths" | grep -qxF "package.json" && # file exists, fetch it
```

Never probe file existence with per-file `/contents/` calls in a loop.

---

## Workflow patterns

### Queue and quota management

Three workflows protect the system from quota exhaustion cascades and runner starvation:

| Workflow | Schedule | Purpose |
|---|---|---|
| `queue-manager.yml` | Every 15 min + after `rate-limit-rerun` | Deduplicates queued runs (keeps newest per workflow) and evicts runs queued > 25 min |
| `quota-reserve.yml` | Every 10 min + after `rate-limit-rerun` | Cancels low-priority queued runs when quota drops below 1000 |
| `critical-deploy.yml` | Manual only | Fast-lane: commit + push → aggressive queue clear → priority dispatch |

**Priority tiers** — single source of truth in `config/workflow-priority-tiers.yml`:
- Tier 1 CRITICAL — never cancelled (token rotation, queue/reserve management, config validation)
- Tier 2 HIGH — mirror chain, sync operations
- Tier 3 MEDIUM — READMEs, CI checks (default for unknown workflows)
- Tier 4 LOW — translation, dep graph, maintenance (cancelled first)

When adding a new workflow, add it to `config/workflow-priority-tiers.yml`. Both `queue-manager.sh` and `quota-reserve.sh` load tiers from this file at runtime — no script edits needed.

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

### Quota pre-flight

All hourly/daily/frequent workflows include a quota pre-flight step before doing
any API work. The step sets `skip=true` when remaining < `MIN_QUOTA` and subsequent
steps check `if: steps.quota.outputs.skip == 'false'`.

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

All IDs are authoritative — sourced from `config/gitlab-subgroups.yml`. Do not hardcode them elsewhere.

---

## README management

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
| `ADD_MIRROR_REPO_SYNC` | `fork-sync-all-ona` | admin:repo_hook, read:org, repo, workflow | GitHub / I-D-1896 | 2026-08-13 | add-mirror-repo.yml | [rotate-token.yml] |
| `GITLAB_SYNC_TOKEN` | `fork-sync-all-sync` | api, read_repository, write_repository | GitLab / openos-project | 2027-05-13 | sync-to-gitlab.yml, mirror-osp-to-gitlab.yml, sync-from-gitlab.yml | [rotate-token.yml] |
| `GITLAB_TOKEN` | `Ona-Env-Secret` | api | GitLab / openos-project | 2027-05-17 | Ona dev environment (injected as GITLAB_TOKEN env var); also used by gl-storage-scan, sync-to-gitlab-variant, cleanup-pollution, reconcile-org-refs | [rotate-token.yml] |
| `FORK_SYNC_TOKEN` | unknown | unknown | GitHub | unknown | ⚠️ not referenced in any workflow — candidate for deletion | [rotate-token.yml] |
| `GITLAB_TOKEN_EXTRA` | unknown | unknown | GitLab | unknown | ⚠️ not referenced in any workflow — candidate for deletion | [rotate-token.yml] |
| `MODELS_TOKEN` | unknown | unknown | unknown | unknown | ⚠️ not referenced in any workflow — candidate for deletion | [rotate-token.yml] |
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

### Automated monitoring

`token-health.yml` runs weekly (Monday 09:00 UTC) and warns at 45 days before expiry.
When a token needs attention it opens a GitHub issue labelled `token-monitor`.
Run it manually at any time to get a current status report.

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
