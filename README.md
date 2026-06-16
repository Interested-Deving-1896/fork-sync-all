# fork-sync-all

[![Built with Ona](https://ona.com/build-with-ona.svg)](https://app.ona.com/#https://github.com/OpenOS-Project-OSP/fork-sync-all)

Sync and mirror infrastructure for the three-org chain:

```
Interested-Deving-1896  ──►  OpenOS-Project-OSP  ──►  OpenOS-Project-Ecosystem-OOC
        ▲                                                         │
        └─────────── upstream-commits / upstream-prs ────────────┘
                                    │
                                    ▼
                         GitLab openos-project
                    (11 subgroups, ~150 repos mirrored)
```

<!-- AI:start:what-it-does -->
_What it does pending._
<!-- AI:end:what-it-does -->

---

## Documentation

- [Full documentation](https://interested-deving-1896.github.io/fork-sync-all/) — architecture, quota management, workflow reference, runbooks
- [Workflow Triggers](docs/workflow-triggers.md) — every workflow, its schedule, and what else triggers it ([plain text](docs/workflow-triggers.txt))

---

## Workflows

### Sync & Mirror

| Workflow | Schedule | What it does |
|---|---|---|
| `sync-forks.yml` | Daily `06:00` | Syncs all `Interested-Deving-1896` forks with their upstreams |
| `sync-pieroproietti-forks.yml` | Every 4h `:05` | Fast-path sync for pieroproietti forks only |
| `mirror-to-osp.yml` | Every 6h `:00` | Mirrors `Interested-Deving-1896` repos into `OpenOS-Project-OSP` |
| `mirror-osp-to-gitlab.yml` | Every 4h `:30` | Mirrors `OpenOS-Project-OSP` repos into GitLab `openos-project` |
| `sync-from-gitlab.yml` | Daily `04:22` | Pulls GitLab `openos-project` repos back into `Interested-Deving-1896` (scheduled fallback; primary trigger is GitLab CI on push) |
| `sync-registered-imports.yml` | Every 6h `:55` | Re-syncs all repos registered via the import workflow |

### Import

| Workflow | Trigger | What it does |
|---|---|---|
| `import-repo.yml` | Manual | Imports any git repo from any platform into `Interested-Deving-1896` |

**Import workflow inputs:**
- `repo_url` — source URL (GitHub, GitLab, Bitbucket, Codeberg, Sourcehut, Gitea, or any git host)
- `repo_name` — optional rename in `Interested-Deving-1896` (defaults to source name)
- `mirror_to_osp_ooc` — push through the OSP → OOC chain immediately
- `ongoing_sync` — register in `registered-imports.json` for re-sync every 6h

### Quota and queue management

| Workflow | Schedule | What it does |
|---|---|---|
| `full-chain-flush.yml` | On `validate-config` success / manual | Master orchestrator — runs the full mirror chain in sequence |
| `queue-manager.yml` | Every 15 min | Deduplicates queued runs; evicts runs queued > 25 min |
| `quota-reserve.yml` | Every 10 min | Cancels low-priority queued runs when quota < 1000 |
| `validate-config.yml` | On push / PR | Validates all config files; runs AgentShield security scan (opt-in) |

### Security and token management

| Workflow | Schedule | What it does |
|---|---|---|
| `token-health.yml` | Weekly Monday `09:00` | Checks GitHub + GitLab PAT expiry; opens an issue at 45 days out |
| `rotate-token.yml` | Manual | Rotates any repo secret via workflow dispatch |

### Maintenance

| Workflow | Schedule | What it does |
|---|---|---|
| `reconcile-org-refs.yml` | Manual / on push | Rewrites org names in file content across all three orgs |
| `upstream-commits.yml` | Every 6h `:47` | Detects direct commits to OSP/OOC and opens PRs in `Interested-Deving-1896` |
| `upstream-prs.yml` | Every 6h `:33` | Syncs open PRs from OSP/OOC upstream into `Interested-Deving-1896` |
| `add-mirror-repo.yml` | Manual | Adds a new repo to the OSP + OOC mirror chain |
| `setup-osp-mirrors.yml` | Manual | Injects `mirror-osp-to-ooc.yaml` into all OSP repos |
| `resolve-failures.yml` | Daily `07:30` | AI-assisted CI failure resolver (GitHub Models) |
| `upstream-workflow-proposal.yml` | Weekly Monday `06:00` | Scans OSP-bound repos for new workflows; opens a PR to propose as a template skeleton |
| `rebase-lts.yml` | Weekly | Rebases the `lts` branch of `penguins-eggs` |
| `sync-eggs-docs-to-book.yml` | On push | Syncs `penguins-eggs` docs into `penguins-eggs-book` |
| `mirror-artifacts.yml` | Scheduled | Mirrors release artifacts (packages, containers, flatpaks) |
| `ota-discover.yml` | Scheduled | Discovers OTA update payloads across OSP-bound repos |

---

## Secrets

| Secret | Used by | Notes |
|---|---|---|
| `SYNC_TOKEN` | All workflows | GitHub PAT — `repo` + `workflow` + `admin:org` scopes |
| `GH_SYNC_TOKEN` | GitLab CI `sync-from-gitlab` job | Same PAT stored as a GitLab CI variable |
| `GITLAB_SYNC_TOKEN` | `mirror-osp-to-gitlab.yml`, `sync-from-gitlab.yml` | GitLab PAT — `api` + `write_repository` on `openos-project` group |
| `BITBUCKET_TOKEN` | `import-repo.yml`, `sync-registered-imports.yml` | Bitbucket app password (private repos only) |
| `GITEA_TOKEN` | `import-repo.yml`, `sync-registered-imports.yml` | Gitea/Codeberg PAT (private repos only) |
| `ADD_MIRROR_REPO_SYNC` | `add-mirror-repo.yml` | Scoped PAT for repo creation |
| `ACTIVITYSMITH_API_KEY` | `full-chain-flush.yml` | Optional — live activity tracking; skipped if unset |
| `ANTHROPIC_API_KEY` | `validate-config.yml` | Optional — AgentShield security scan; skipped if unset |

To add a missing secret, run in your terminal (value prompted securely, never logged):

```bash
gh secret set <SECRET_NAME> --repo Interested-Deving-1896/fork-sync-all
```

---

## Registered Imports

`registered-imports.json` tracks repos imported via `import-repo.yml` with `ongoing_sync` enabled. The `sync-registered-imports.yml` workflow reads this file hourly and re-pulls each source.

Schema:
```json
[
  {
    "source_url":  "https://gitlab.com/some-group/some-repo",
    "target_name": "some-repo",
    "platform":    "gitlab",
    "added":       "2026-05-02T18:00:00Z"
  }
]
```

To register a repo manually, run `import-repo.yml` with `ongoing_sync: true`, or edit the file directly and commit.

---

## Rate limits

All workflows share a single `SYNC_TOKEN`. Understanding the limits prevents
surprise failures and helps diagnose them when they do occur.

### GitHub REST API

| Limit type | Threshold | Reset | Header |
|---|---|---|---|
| Primary (per token) | 5 000 req/hr | Top of the hour | `X-RateLimit-Reset` (epoch) |
| Secondary (burst/concurrency) | No fixed number — triggered by rapid sequential requests | ~60 s cooldown | `X-RateLimit-Reset` or `Retry-After` |
| Unauthenticated | 60 req/hr per IP | Top of the hour | `X-RateLimit-Reset` |

**What a 403/429 means here:** GitHub returns HTTP `403` for secondary rate
limits and HTTP `429` for primary exhaustion. Both include `X-RateLimit-Reset`
in the response headers. All scripts that call the GitHub API read this header
and sleep until the reset window opens before retrying (up to 3 attempts).

**Workflows most likely to hit limits:** `sync-forks.yml` (scans all forks),
`reconcile-org-refs.yml` (reads every file in every repo), and
`resolve-failures.yml` (scans all repos across three orgs). These run
sequentially within their own concurrency group so they don't compound each
other's usage.

**If a workflow fails with "API rate limit exceeded":** the next scheduled run
will succeed once the window resets. `resolve-failures.yml` will also catch and
retry it automatically. No manual intervention is needed unless the token itself
has been revoked.

### GitHub Models API

Used by `resolve-failures.yml` and `create-readmes.yml` / `update-readmes.yml`
for AI-assisted analysis and generation.

| Limit type | Behaviour | Header |
|---|---|---|
| Per-token quota | Varies by model; `gpt-4o-mini` has the highest allowance | `Retry-After` (seconds) |
| Rate (requests/min) | Model-dependent | `Retry-After` |

HTTP `429` from the Models API includes a `Retry-After` header. Scripts read
this and sleep for the indicated duration before retrying (up to 3 attempts).
If the quota is fully exhausted the script logs
`[models-rate-limit] GitHub Models quota exhausted` and skips AI analysis for
that run — the workflow still exits 0 so it doesn't generate a false failure
notification.

### GitLab API

Used by `mirror-osp-to-gitlab.yml`, `sync-from-gitlab.yml`, and
`sync-to-gitlab.yml`.

| Limit type | Threshold | Reset | Header |
|---|---|---|---|
| Authenticated REST | 2 000 req/min per token | Per-minute window | `RateLimit-Reset` (epoch) |
| Unauthenticated | 500 req/min per IP | Per-minute window | `RateLimit-Reset` |

HTTP `429` (and occasionally `403`) from GitLab includes a `RateLimit-Reset`
header. Scripts read this and sleep until the window resets before retrying.

### git push limits

Mirror scripts that push via HTTPS (`mirror-to-osp.yml`,
`mirror-osp-to-ooc.yaml`, `sync-to-gitlab.yml`, `sync-registered-imports.yml`,
etc.) can hit transient push rejections under load — these are not HTTP API
limits but git-level errors. All push steps retry up to 3 times with linear
backoff (15 s, 30 s, 45 s) before failing.

The `mirror-osp-to-ooc.yaml` workflow additionally uses a `concurrency` group
(`mirror-to-ooc`) so concurrent runs queue rather than race, which eliminates
the `cannot lock ref` class of push failures.

### Diagnosing a rate-limit failure

1. Open the failed run log and search for `[rate-limit]` or `rate limit exceeded`.
2. The log line includes the HTTP status, sleep duration, and attempt number.
3. If all 3 retries were exhausted the next scheduled run will succeed
   automatically — primary limits reset hourly, secondary limits within ~60 s.
4. If failures persist across multiple scheduled runs, check that `SYNC_TOKEN`
   is valid (`gh auth status`) and has the required scopes (`repo`, `workflow`,
   `admin:org`).

### GitHub Actions runner minutes

**Free tier:** 2,000 min/month (Linux, resets 1st of each month). All jobs use
`ubuntu-latest` (1× multiplier). At the current schedule density (~7 hourly
workflows), this repo exceeds the free tier. **A paid plan or self-hosted
runner is required.**

**Symptoms of exhaustion:** `ubuntu-latest` jobs queue indefinitely, 0
in-progress runs, no runners active. Check via **Settings → Billing → Actions**.

**Recovery:** Cancel all queued runs (they will never start), then wait for the
monthly reset or add a self-hosted runner.

```bash
# Bulk cancel all queued runs (requires API quota)
gh api "repos/Interested-Deving-1896/fork-sync-all/actions/runs?per_page=100" \
  --jq '[.workflow_runs[] | select(.status=="queued") | .id] | .[]' | \
  xargs -I{} gh api -X POST \
    "repos/Interested-Deving-1896/fork-sync-all/actions/runs/{}/cancel"
```

### Concurrency groups and stuck runs

All workflows use `cancel-in-progress: true`. A newer run always supersedes a
queued one, preventing permanent queue buildup when runner minutes are exhausted
mid-job.

**Detecting stuck runs:**
```bash
gh api "repos/Interested-Deving-1896/fork-sync-all/actions/runs?per_page=100" \
  --jq '[.workflow_runs[] | select(.status=="queued")] | length'
```

### workflow_run trigger cost

`workflow_run` fires on every `completed` event regardless of conclusion. All
listeners in this repo gate at the job level so they exit immediately (no
runner cost) when the upstream conclusion doesn't match:

- Content processors (`create-readmes`, `update-readmes`, `inject-badges`,
  `translate-readmes`, `lts-readmes`, `mirror-osp-to-gitlab`): gate on
  `conclusion == 'success'`
- Watchdogs (`mirror-orgs-watchdog`): gate on `conclusion == 'failure'`

See [DOCS/OPERATIONS.md](DOCS/OPERATIONS.md) for the full operational
reference: quota tables, schedule summary, self-hosted runner setup, and
quick-reference reset times.

## GitLab subgroups

11 subgroups under `gitlab.com/openos-project`, ~150 repos mirrored:

| Subgroup | Repos | Focus |
|---|---|---|
| `git-management_deving` | 4 | Git tooling and org management |
| `penguins-eggs_deving` | 3 | penguins-eggs distro tools |
| `immutable-filesystem_deving` | varies | Immutable filesystem projects |
| `linux-kernel_filesystem_deving` | 15 | Kernel and filesystem repos |
| `incus_deving` | varies | Incus container/VM tooling |
| `taubyte_deving` | 8 | Taubyte protocol repos |
| `neon-deving` | varies | KDE Neon repos |
| `ops` | 5 | Infrastructure and tooling |
| `yaml-tooling_deving` | 29 | YAML tools, linters, schema validators, GH Actions tooling |
| `cachyos_deving` | 15 | CachyOS distro packages |
| `ai-agents_deving` | 12 | AI agent frameworks and tools |

Subgroup IDs and repo assignments are in `config/gitlab-subgroups.yml`.

---

## Mirror chain timing

```
:00  mirror-to-osp.yml          Interested-Deving-1896 → OSP
:05  sync-pieroproietti          pieroproietti forks fast-path
:10  quota-reserve.yml           Cancel low-priority runs if quota < 1000
:15  queue-manager.yml           Deduplicate queued runs
:15  mirror-osp-to-ooc.yaml      OSP → OOC  (per-repo, injected by setup-osp-mirrors)
:23  upstream-prs.yml            OOC/OSP PRs → Interested-Deving-1896
:30  mirror-osp-to-gitlab.yml    OSP → GitLab openos-project
:45  upstream-commits.yml        Direct OSP/OOC commits → PRs in Interested-Deving-1896
:55  sync-registered-imports     External platform imports re-sync

Full chain (validate-config → full-chain-flush) runs on every push to main.
```

<!-- AI:start:mirror-chain -->
This repo is maintained in [`Interested-Deving-1896/fork-sync-all`](https://github.com/Interested-Deving-1896/fork-sync-all) and mirrored through:

```
Interested-Deving-1896/fork-sync-all  ──►  OpenOS-Project-OSP/fork-sync-all  ──►  OpenOS-Project-Ecosystem-OOC/fork-sync-all
```

Changes flow downstream automatically via the hourly mirror chain in
[`fork-sync-all`](https://github.com/Interested-Deving-1896/fork-sync-all).
Direct commits to OSP or OOC are detected and opened as PRs back to `Interested-Deving-1896`.
<!-- AI:end:mirror-chain -->

---

## Architecture

<!-- AI:start:architecture -->
_Architecture pending._
<!-- AI:end:architecture -->

---

## CI

<!-- AI:start:ci -->
_CI pending._
<!-- AI:end:ci -->

---

## Origins

<!-- AI:start:origins -->
### Logic extracted from

| Project | What |
|---|---|
| [andrewthetechie/gha-repo-manager](https://github.com/andrewthetechie/gha-repo-manager) | Declarative repo settings drift detection pattern and settings.yml schema; reimplemented as a shell script using gh-api.sh () |
| [ioncakephper/repo-description](https://github.com/ioncakephper/repo-description) | Per-file AI description generation pattern; reimplemented using llm.sh + GitHub Models (gpt-4o-mini) instead of Groq + Node.js () |
| [msoap/shell2http](https://github.com/msoap/shell2http) | HTTP server that executes shell scripts as endpoints; primary transport backend for vendor/unified-agnostic-api server/ () |
| [adnanh/webhook](https://github.com/adnanh/webhook) | Lightweight webhook server triggering shell scripts; alternate backend for vendor/unified-agnostic-api server/ () |
| [Lifailon/bash-api-server](https://github.com/Lifailon/bash-api-server) | Apache CGI REST API pattern in pure bash; CGI fallback backend and deploy-cgi.sh pattern () |
| [locus313/github-api-scripts](https://github.com/locus313/github-api-scripts) | Org admin bash scripts for bulk permissions, repo creation, and monthly reports; adapted into github adapter () |
| [CadmusCJung/git-release-shell](https://github.com/CadmusCJung/git-release-shell) | GitHub Releases via curl/shell; release creation pattern adapted into adapters/github/create-release.sh () |
| [Trusera/ai-bom](https://github.com/Trusera/ai-bom) | AI Bill of Materials scanner (CycloneDX/SARIF/SPDX); wrapped in adapters/ai/bom-scan.sh with built-in fallback scanner () |

### Inspired by

| Project | What |
|---|---|
| [gabrie30/ghorg](https://github.com/gabrie30/ghorg) | Bulk org cloning concept; reimplemented natively for GitHub Actions without requiring a Go binary on the runner () |
| [svandragt/repoman](https://github.com/svandragt/repoman) | Repo manifest export/import concept; extended to support multi-platform sources and bulk GitHub org import () |
| [helpmatteo/multirepos-to-monorepo](https://github.com/helpmatteo/multirepos-to-monorepo) | filter-repo + LFS preservation + tag prefixing approach for monorepo merges () |
| [sebmellen/monorepo-importer](https://github.com/sebmellen/monorepo-importer) | Sequential merge approach for preserving per-repo commit history () |
| [chrisdothtml/monorepo-import](https://github.com/chrisdothtml/monorepo-import) | Commit-replay strategy for clean history rewriting during monorepo import () |
| [swingbit/mergeGitRepos](https://github.com/swingbit/mergeGitRepos) | YAML branch mapping schema for declarative multi-repo merge configuration () |
| [robinst/git-merge-repos](https://github.com/robinst/git-merge-repos) | N-parent merge commit pattern; reimplemented in native bash without Java dependency () |
| [actions/github-script](https://github.com/actions/github-script) | Workflow-dispatch-as-API pattern; influenced the design of the critical deploy chain and dispatch-and-wait.sh () |
| [bashly-framework/bashly](https://github.com/bashly-framework/bashly) | Bash CLI framework and generator; CLI argument parsing and subcommand routing pattern in cli/uaa.sh () |
| [Bash-it/bash-it](https://github.com/Bash-it/bash-it) | Community bash framework with plugins, aliases, and themes; lib/ include structure and sourcing conventions () |
| [Flux159/agentic-shell](https://github.com/Flux159/agentic-shell) | LLM-driven natural language shell (AGIsh); concept and safety model adapted into adapters/ai/agentic-shell.sh () |
| [zen-fs/core](https://github.com/zen-fs/core) | Cross-platform virtual FS abstraction with pluggable backends; mount registry and backend plugin architecture in filesystem adapter () |
| [scottvr/apifusefs](https://github.com/scottvr/apifusefs) | OpenAPI spec → FUSE filesystem bridge; API-as-filesystem concept applied to routes.yml → adapter mapping () |
| [rmatsuoka/apifs](https://github.com/rmatsuoka/apifs) | Plan 9-style API-as-filesystem in Go; filesystem-as-API routing concept in lib/routes.sh () |
| [fmartini23/cross-platform-system-interaction](https://github.com/fmartini23/cross-platform-system-interaction) | Node.js cross-platform OS abstraction (file/process/clipboard); namespace structure adapted into os-compat adapter () |
| [tislib/apibrew](https://github.com/tislib/apibrew) | Declarative YAML → REST/gRPC API generator; routes.yml declarative route manifest design () |
| [beamitpal/unified-ai-api](https://github.com/beamitpal/unified-ai-api) | Design spec for a platform-agnostic native AI API; multi-provider routing pattern in adapters/ai/complete.sh () |
| [notgiven688/jail-sh](https://github.com/notgiven688/jail-sh) | Bash shell with filesystem access restricted by Linux Landlock; sandboxing concept applied to UAA_FS_ROOTS path restriction in filesystem adapter () — Tracked as registered import in agnostic-api_deving subgroup |
| [leifdenby/shellqueue](https://github.com/leifdenby/shellqueue) | Filesystem-based task queue in Python/shell; queue-as-filesystem concept referenced for adapter job queuing design — Tracked as registered import in ops subgroup |

### Used as reference

| Project | What |
|---|---|
| [turahe/git-repo-manager](https://github.com/turahe/git-repo-manager) | Multi-platform repo management CLI; referenced for GitLab group pagination and concurrent clone patterns () |
| [hakoerber/git-repo-manager](https://github.com/hakoerber/git-repo-manager) | Declarative local repo and worktree management via TOML/YAML; referenced for worktree lifecycle patterns — Forked as git-repo-worktrees-manager in Interested-Deving-1896 |
| [chopratejas/headroom](https://github.com/chopratejas/headroom) | Context compression proxy for LLM agents; referenced for token-budget management patterns in llm.sh () — Tracked as a registered import and deployed in the ops GitLab subgroup |
| [kohofinancial/rtk](https://github.com/kohofinancial/rtk) | High-performance Rust token compression proxy; referenced alongside headroom for LLM token reduction strategies — Tracked as a registered import in the ops GitLab subgroup |
| [nautilus-cyberneering/git-queue](https://github.com/nautilus-cyberneering/git-queue) | Git-native queue implementation; referenced for queue-manager.sh's deduplication and eviction logic () — Tracked as a registered import |
| [pa11y/pa11y](https://github.com/pa11y/pa11y) | Automated accessibility testing CLI; used directly in check-accessibility.sh for WCAG audit () |
| [rust-lang/mdBook](https://github.com/rust-lang/mdBook) | Static site generator for documentation books; used directly in deploy-book.yml to render DOCS/ () |
| [DamageLabs/clahub](https://github.com/DamageLabs/clahub) | CLA management via GitHub; referenced for contributor agreement workflow patterns — Tracked as a registered import in the ai-agents_deving GitLab subgroup |
| [yennanliu/utility_shell](https://github.com/yennanliu/utility_shell) | General-purpose bash utility collection; referenced for cross-platform shell patterns in os-compat adapter () |
| [alexkli/github-api-scripts](https://github.com/alexkli/github-api-scripts) | GitHub REST API shell scripts; referenced for curl-based API call patterns in github adapter () |
| [GoogleChromeLabs/browser-fs-access](https://github.com/GoogleChromeLabs/browser-fs-access) | Browser File System Access API ponyfill; referenced for browser-side FS abstraction patterns () |
| [SupraSummus/ipfs-api-mount](https://github.com/SupraSummus/ipfs-api-mount) | IPFS directory → FUSE mount with caching; ipfs backend type in filesystem/mount.sh () |
| [lifo-sh/lifo](https://github.com/lifo-sh/lifo) | Browser-native Unix OS with VFS, shell, and 60+ coreutils; referenced for browser runtime layer design () |
| [topboyasante/api-base](https://github.com/topboyasante/api-base) | Go API scaffold with Swagger, metrics, and modular monolith architecture; referenced for adapter manifest.yml structure () |
| [Alex313031/puppeteer](https://github.com/Alex313031/puppeteer) | Puppeteer fork for CDP-based browser control; referenced for screenshot and automation adapter tooling () |
| [quitecode9-lab/chromium-automation](https://github.com/quitecode9-lab/chromium-automation) | Lightweight CDP automation library; referenced for browser step action model in adapters/browser/automate.sh () |
| [dyne/tomb](https://github.com/dyne/tomb) | Encrypted filesystem container using dm-crypt/LUKS; referenced for secure storage patterns in filesystem adapter () — Tracked as registered import in agnostic-api_deving subgroup |
| [vadmium/mkinitcpio-dir](https://github.com/vadmium/mkinitcpio-dir) | Initcpio hook to mount a subdirectory as the root filesystem; referenced for early-boot FS mount patterns — Tracked as registered import in agnostic-api_deving subgroup |
| [digitaltvguy/fswatch-Filesystem-Events-Watchfolder-Shell-Script](https://github.com/digitaltvguy/fswatch-Filesystem-Events-Watchfolder-Shell-Script) | Shell script for fswatch watchfolder with growing-file detection; referenced for filesystem event patterns in filesystem adapter () — Tracked as registered import in agnostic-api_deving subgroup |
| [zdk/rm-safely](https://github.com/zdk/rm-safely) | Safe rm wrapper that moves files to trash instead of deleting; referenced for safe file operation patterns — Tracked as registered import in agnostic-api_deving subgroup |
| [andrachiritoiu/User-Filesystem](https://github.com/andrachiritoiu/User-Filesystem) | Monitors active users and represents them as a filesystem; referenced for user-as-filesystem abstraction concept — Tracked as registered import in agnostic-api_deving subgroup |
| [jogor9/swap.sh](https://github.com/jogor9/swap.sh) | Safely swaps two files on a filesystem using atomic rename; referenced for safe file swap in filesystem write adapter () — Tracked as registered import in agnostic-api_deving subgroup |
| [jsbmg/mist.sh](https://github.com/jsbmg/mist.sh) | Syncs directories securely via SSH filesystem; referenced for remote sync patterns in os-compat adapter — Tracked as registered import in agnostic-api_deving subgroup |
| [sevenreasons/sizes](https://github.com/sevenreasons/sizes) | Fast CLI for extension-based disk usage summaries; referenced for filesystem stat and size reporting in filesystem adapter () — Tracked as registered import in agnostic-api_deving subgroup |
| [aplund/bibhelper](https://github.com/aplund/bibhelper) | Bibliographic database using shell scripts and ordinary filesystem features; referenced for filesystem-as-database pattern — Tracked as registered import in agnostic-api_deving subgroup |
| [dparoli/hrsync](https://github.com/dparoli/hrsync) | rsync backup with moved/renamed file detection; referenced for sync patterns in remote-sync and os-compat adapters — Tracked as registered import in ops subgroup |
| [CodesOfRishi/smartcd](https://github.com/CodesOfRishi/smartcd) | Smart cd with filesystem navigation shortcuts and history; referenced for shell navigation patterns in cli/uaa.sh () — Tracked as registered import in ops subgroup |
| [PavaraM/Smart-File-Organizer](https://github.com/PavaraM/Smart-File-Organizer) | Auto-sorts files into folders by type using bash; referenced for file classification patterns in filesystem adapter — Tracked as registered import in ops subgroup |
| [pinkorca/namefix](https://github.com/pinkorca/namefix) | Cross-platform filename sanitizer and validator; referenced for safe path handling in filesystem write adapter () — Tracked as registered import in ops subgroup |
| [Amalzalu/operation-phantom-shell](https://github.com/Amalzalu/operation-phantom-shell) | Bash scripting challenges covering log analysis, process monitoring, and system automation; referenced for os-compat adapter patterns () — Tracked as registered import in ops subgroup |
| [omyldrm/linux-shell-script-archive](https://github.com/omyldrm/linux-shell-script-archive) | Archives and searches .sh files in home directory; referenced for script discovery patterns in cli/uaa.sh — Tracked as registered import in ops subgroup |
| [tchartron/remote-sync](https://github.com/tchartron/remote-sync) | Remote server folder sync via rsync/SSH; referenced for remote filesystem sync patterns in os-compat adapter — Tracked as registered import in ops subgroup |
| [nathanielop/achievements](https://github.com/nathanielop/achievements) | Shell scripts to unlock GitHub achievements via API; referenced for GitHub API automation patterns in github adapter () — Tracked as registered import in ops subgroup |
| [niklasberglund/ipinfo](https://github.com/niklasberglund/ipinfo) | Bash wrapper for ipinfo.io IP address API; referenced for curl-based API wrapper patterns in github adapter — Tracked as registered import in ops subgroup |
| [konzy/mass_clone](https://github.com/konzy/mass_clone) | Shell script to clone multiple repositories; referenced for bulk repo operation patterns in github adapter () — Tracked as registered import in ops subgroup |
| [Vaelatern/simple-deploy](https://github.com/Vaelatern/simple-deploy) | Collection of simple software deployment approaches; referenced for deployment pattern design in server/start.sh () — Tracked as registered import in ops subgroup |

---


> Auto-generated by `generate-dep-graph.sh`. Do not edit manually.
> Last generated: 2026-06-12 (stub — full graph generated on next scheduled run)

This graph maps every OSP-bound repo in `Interested-Deving-1896` to its upstream
origin(s), as declared in each repo's `## Origins` README section.

| Repo | Origin | Host | Fork in I-D-1896 |
|------|--------|------|-----------------|
| `github-codeowners` | [kohofinancial/github-codeowners](https://github.com/kohofinancial/github-codeowners) | GitHub | ✅ |
| `github-codeowners` | [jjmschofield/github-codeowners](https://github.com/jjmschofield/github-codeowners) | GitHub | ❌ |
| `gitlab-enhanced` | [openos-project/git-management_deving/gitlab-enhanced](https://gitlab.com/openos-project/git-management_deving/gitlab-enhanced) | GitLab | ✅ |

## Summary

- OSP-bound repos scanned: **stub** *(full scan runs weekly via `generate-dep-graph.yml`)*
- Tooling dependencies tracked: `github-codeowners` (CODEOWNERS auditing across all OSP repos)

## Tooling Dependencies

| Tool | Purpose | Upstream |
|------|---------|---------|
| [github-codeowners](https://github.com/Interested-Deving-1896/github-codeowners) | Audits CODEOWNERS coverage — surfaces ownership stats per repo | [kohofinancial/github-codeowners](https://github.com/kohofinancial/github-codeowners) |
<!-- AI:end:origins -->

---

## Resources

<!-- AI:start:resources -->
| File | Description |
|---|---|
| [dep-graph/origins.md](https://github.com/Interested-Deving-1896/fork-sync-all/blob/main/dep-graph/origins.md) | Dependency graph (Markdown table) |
| [dep-graph/provenance.yml](https://github.com/Interested-Deving-1896/fork-sync-all/blob/main/dep-graph/provenance.yml) | Structured upstream provenance — inspirations, extractions, references |
| [registered-imports.json](https://github.com/Interested-Deving-1896/fork-sync-all/blob/main/registered-imports.json) | Registered ongoing-sync imports |
| [config/gitlab-subgroups.yml](https://github.com/Interested-Deving-1896/fork-sync-all/blob/main/config/gitlab-subgroups.yml) | GitLab subgroup map |
| [config/repo-settings.yml](https://github.com/Interested-Deving-1896/fork-sync-all/blob/main/config/repo-settings.yml) | Declarative repo settings (drift detection + enforcement) |
| [.gitlab/merge_request_templates/Default.md](https://github.com/Interested-Deving-1896/fork-sync-all/blob/main/.gitlab/merge_request_templates/Default.md) | GitLab MR template |
<!-- AI:end:resources -->

---

## Contributors

<!-- AI:start:contributors -->
_Contributors pending._
<!-- AI:end:contributors -->

---

## Accessibility

<!-- AI:start:accessibility -->
This repo uses automated accessibility auditing via `check-accessibility.yml`.

Checks include: CODEOWNERS ownership coverage, README screen-reader compatibility,
WCAG 2.1 AA HTML compliance, audio overview (espeak-ng), and Braille output (liblouis).




Run the [Check Accessibility](https://github.com/Interested-Deving-1896/fork-sync-all/actions/workflows/check-accessibility.yml)
workflow to generate the first report and accessibility artifacts.
See [DOCS/accessibility.md](https://github.com/Interested-Deving-1896/fork-sync-all/blob/main/DOCS/accessibility.md) for the full reference.
<!-- AI:end:accessibility -->

---

## License

<!-- AI:start:license -->
[GPL-3.0](https://github.com/Interested-Deving-1896/fork-sync-all/blob/main/LICENSE) © 2026 [Interested-Deving-1896](https://github.com/Interested-Deving-1896)
<!-- AI:end:license -->
