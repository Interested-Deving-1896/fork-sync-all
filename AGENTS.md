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

| Secret | Scope | Org | Expiry | Rotate via |
|---|---|---|---|---|
| `SYNC_TOKEN` | repo, workflow, admin:org | Interested-Deving-1896 | see token-health workflow | [rotate-token.yml] |
| `GH_SYNC_TOKEN` | repo, workflow | Interested-Deving-1896 | see token-health workflow | [rotate-token.yml] |
| `ADD_MIRROR_REPO_SYNC` | repo | Interested-Deving-1896 | see token-health workflow | [rotate-token.yml] |
| `GITLAB_SYNC_TOKEN` | api, read_repository | GitLab | see token-health workflow | [rotate-token.yml] |
| `ORG_MIRROR_OSP_TO_OOC` | repo | OpenOS-Project-OSP | **2026-06-28** | [OSP org secrets] |
| `MIRROR_TOKEN` | repo | OpenOS-Project-OSP | **2026-07-03** | [OSP org secrets] |

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

OSP org secrets cannot be updated via the repo API — they live in the
`OpenOS-Project-OSP` org and require org admin access:

1. Generate a new PAT at https://github.com/settings/tokens
2. Go to [OSP org secrets] and update the secret value
3. Update the expiry date in `scripts/token-monitor.sh` (the `OSP_ORG_SECRETS` array)
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
