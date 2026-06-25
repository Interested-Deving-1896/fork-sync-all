# fsa-api — Fork-Sync-All API

A two-layer HTTP API that exposes the entire fork-sync-all control plane —
workflows, scripts, mirror chain, docs, deployments, and codebase state —
over a uniform REST interface. Works across all 5 git platforms.

```
fsa-api/
  uaa/        — Unified Agnostic API (generic, reusable by any consumer repo)
  core/       — FSA-specific adapter layer (extends UAA for fork-sync-all)
  config/     — FSA route manifest + feature toggles + consumer config
  server/     — FSA HTTP server (merges UAA + FSA routes)
  cli/        — fsa CLI (local + remote dispatch)
```

## Architecture

```
Android App / WebUI / CLI / any HTTP client
              │
              ▼
    fsa-api/server/fsa-start.sh
              │  merges UAA routes + FSA routes, applies toggles
              │
    ┌─────────┴──────────┐
    │                    │
  UAA layer           FSA core layer
  /health              /api/fsa/workflows/*
  /api/adapters        /api/fsa/repos/*
  /api/filesystem/*    /api/fsa/chain/*
  /api/os/*            /api/fsa/quota
  /api/ai/*            /api/fsa/notifications/*
  /api/github/*        /api/fsa/docs/*
  (25 routes)          /api/fsa/deployments/*
                       /api/fsa/codebase/*
                       /api/fsa/bdfs/*
                       /api/fsa/security/*
                       /api/fsa/toggles/*
                       (29 routes)
```

**`uaa/`** is the generic foundation — platform-agnostic adapters for filesystem,
OS, AI, browser, GitHub generic. Consumer repos copy this as-is and build their
own `core/` on top. It has no knowledge of fork-sync-all.

**`core/`** is the FSA-specific layer — adapters that expose fork-sync-all's
control plane as HTTP endpoints. All core adapters source `core/lib/fsa-adapter.sh`
which extends UAA's `adapter.sh` with GitHub/multi-platform API access, quota
guards, toggle helpers, and deployment registry access.

**`uaa/lib/shared.sh`** is the bidirectional sync point between UAA and FSA-API.
It contains platform-agnostic logic that both layers share: toggle system,
generic quota guard, JSON helpers, multi-file route merge, capability registry.
FSA-API overrides `quota_fetch()` with the GitHub-specific implementation;
UAA defaults to unlimited.

## Quick start

```bash
# Start the FSA API server (port 8080)
bash fsa-api/server/fsa-start.sh

# Or use the CLI directly (no server needed)
bash fsa-api/cli/fsa.sh workflow list
bash fsa-api/cli/fsa.sh workflow run sync-forks
bash fsa-api/cli/fsa.sh quota status
bash fsa-api/cli/fsa.sh chain status
bash fsa-api/cli/fsa.sh toggle list
```

## HTTP API — 54 routes total (29 FSA + 25 UAA)

### Workflows (platform-aware)

```
GET  /api/fsa/workflows              list all workflows + tier + toggle state
                                     ?filter=enabled|disabled|all  ?tier=1|2|3|4
                                     ?platform=github|gitlab|gitea|forgejo
POST /api/fsa/workflows/:name/run    dispatch a workflow / trigger a pipeline
                                     body: {"ref":"main","inputs":{...},"platform":"github"}
GET  /api/fsa/workflows/:name/status last run status
```

Every script in `scripts/` has a corresponding workflow, so every operation
is reachable via `POST /api/fsa/workflows/:name/run` from any client.

### Repos

```
GET  /api/fsa/repos                  list org repos
POST /api/fsa/repos/onboard          onboard a new repo
```

### Mirror chain

```
GET  /api/fsa/chain/status           flush pipeline state, FLUSH_ACTIVE mutex
POST /api/fsa/chain/flush            trigger full-chain-flush.yml
```

### Quota

```
GET  /api/fsa/quota                  REST + GraphQL remaining, reset time
```

### Notifications

```
GET  /api/fsa/notifications          unread GitHub inbox
POST /api/fsa/notifications/triage   auto-mark known-safe patterns as read
```

### Docs / Publishing

```
GET  /api/fsa/docs                   list docs workflows by category
                                     ?category=all|book|readme|translate|sbom|notebooklm
GET  /api/fsa/docs/status            last run status per docs workflow
GET  /api/fsa/docs/content           DOCS/ page index + GitHub Pages URLs + book.toml metadata
                                     ?format=index|toc|pages  ?section=<name>
POST /api/fsa/docs/dispatch          dispatch any docs workflow by name (allowlist-guarded)
                                     body: {"workflow":"deploy-book","ref":"main","inputs":{...}}
```

### Deployments (all 5 FSA instances)

```
GET  /api/fsa/deployments            list all registered FSA instances
                                     ?check=true  ?platform=github|gitlab  ?position=source|mirror
GET  /api/fsa/deployments/:id/status platform API probe + FSA-API health + last run
GET  /api/fsa/deployments/:id/workflows  GitHub Actions workflows or GitLab pipelines
POST /api/fsa/deployments/:id/dispatch   trigger workflow/pipeline on remote instance
GET  /api/fsa/deployments/:id/codebase   SHA drift check for a specific deployment
```

Registered deployments (`config/fsa-deployments.yml`):

| ID | Platform | Org/Group | Position |
|---|---|---|---|
| `source` | GitHub | `Interested-Deving-1896` | source |
| `osp-github` | GitHub | `OpenOS-Project-OSP` | mirror |
| `ooc-github` | GitHub | `OpenOS-Project-Ecosystem-OOC` | mirror |
| `osp-gitlab` | GitLab | `openos-project/ops` | mirror |
| `ooc-gitlab` | GitLab | `openos-project-ooc-ecosystem/ops` | mirror |

### Codebase self-awareness

```
GET  /api/fsa/codebase/status        current SHA, branch, dirty state, ahead/behind,
                                     workflow/script/adapter/route inventory counts
GET  /api/fsa/codebase/drift         cross-deployment SHA comparison (all 5 instances)
                                     ?deployment=all|<id>
GET  /api/fsa/codebase/log           recent commits
                                     ?limit=N  ?since=YYYY-MM-DD  ?author=<name>  ?path=<path>
POST /api/fsa/codebase/sync          trigger self-update on mirror instances
                                     body: {"dry_run":false,"force":false}
                                     force=true uses critical-deploy-gitlab.yml (direct git push)
```

### BDFS

```
GET  /api/fsa/bdfs/status            bdfs workspace status
POST /api/fsa/bdfs/export            export as DwarFS image
POST /api/fsa/bdfs/import            import a DwarFS image
```

### Security

```
GET  /api/fsa/security/scan          dev-machine-guard scan
                                     ?format=json|text  ?categories=all|packages|agents|...
```

### Toggles

```
GET  /api/fsa/toggles                list all feature toggles + enabled state
POST /api/fsa/toggles/:name          set toggle value — body: {"enabled":true|false}
```

### UAA generic endpoints (25 routes)

```
GET  /health                         server health + uptime
GET  /api/adapters                   all registered adapters + capability registry
GET  /api/filesystem/*               read/write/list local files
GET  /api/os/*                       shell exec, env, process info
GET  /api/ai/*                       LLM inference (model-agnostic)
GET  /api/browser/*                  Playwright browser control
GET  /api/github/*                   generic GitHub REST (repos, orgs, releases)
```

## Platform agnosticism

`fsa-adapter.sh` sources `scripts/includes/platform-adapter.sh`, giving every
FSA adapter access to `pa_init / pa_api_get / pa_rate_limit_remaining` for all
5 platforms. Use `fsa_platform_init()` to switch platforms within an adapter:

```bash
# Switch to GitLab for a specific operation
fsa_platform_init gitlab
pa_list_repos "openos-project"

# Switch back to GitHub
fsa_platform_init github
```

Token selection is automatic per platform:

| Platform | Token env var |
|---|---|
| `github` | `GH_TOKEN` / `SYNC_TOKEN` |
| `gitlab` | `GITLAB_TOKEN` |
| `gitea` | `GITEA_TOKEN` |
| `forgejo` | `FORGEJO_TOKEN` |
| `codeberg` | `CODEBERG_TOKEN` |

`workflows/list.sh` and `workflows/run.sh` both have platform branches:
- **GitHub**: reads `.github/workflows/`, dispatches `workflow_dispatch`
- **GitLab**: reads `.gitlab-ci.yml` jobs, triggers pipelines via `/projects/:id/pipeline`
- **Gitea/Forgejo**: reads Actions workflows, dispatches via Gitea API
- **Codeberg**: routes through Forgejo-compatible path

## Feature toggles

Each toggle gates a domain. All enabled by default.

| Toggle | Domain |
|---|---|
| `notifications` | `/api/fsa/notifications/*` |
| `onboarding` | `/api/fsa/repos/onboard` |
| `flush_pipeline` | `/api/fsa/chain/*` |
| `bdfs` | `/api/fsa/bdfs/*` |
| `security` | `/api/fsa/security/*` |
| `docs` | `/api/fsa/docs/*` |
| `deployments` | `/api/fsa/deployments/*` |
| `codebase` | `/api/fsa/codebase/*` |

## Adding a new FSA adapter

1. Create `fsa-api/core/adapters/<domain>/<verb>.sh`
2. Source `fsa-adapter.sh` at the top
3. Add a route entry to `fsa-api/config/fsa-routes.yml`
4. Add a toggle to `fsa-api/config/fsa-toggles.yml` if the domain is new
5. Run `python3 scripts/validate-workflow-guards.py` — zero warnings required

```bash
#!/usr/bin/env bash
# GET /api/fsa/<domain>/<resource>
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/fsa-adapter.sh"

fsa_quota_check 50 || exit 0
toggle_enabled my_toggle || { fsa_error "disabled" 503; exit 0; }

# ... adapter logic ...
fsa_ok '{"result":"..."}'
```

Key helpers from `fsa-adapter.sh`:

| Helper | Source | Purpose |
|---|---|---|
| `fsa_quota_check N` | delegates to `shared.sh` | exit 429 if remaining < N |
| `fsa_ok / fsa_error / fsa_list` | aliases for `json_ok / json_error / json_list` | JSON responses |
| `fsa_api_get / fsa_api_post` | fsa-adapter.sh | GitHub REST with retry |
| `fsa_graphql` | fsa-adapter.sh | GitHub GraphQL (GitHub only) |
| `fsa_platform_init [PLATFORM]` | fsa-adapter.sh | switch active platform |
| `toggle_enabled NAME` | shared.sh | check toggle state |
| `pa_api_get / pa_list_repos` | platform-adapter.sh | platform-agnostic API |
| `merge_routes_files FILE...` | shared.sh | merge multiple route manifests |

## Consumer repo usage

Consumer repos receive the UAA layer only — not FSA's GitHub-specific core adapters.
`sync-template.sh` enforces this via `EXCLUDED_PATHS` in `config/template-manifest.yml`.

To use UAA in your own repo:
1. Copy `fsa-api/uaa/` into your repo as `my-api/uaa/`
2. Create `my-api/core/adapters/` with your platform-specific adapters
3. Create `my-api/config/routes.yml` extending `uaa/config/routes.yml`
4. Start with `bash my-api/server/start.sh`

`fsa-api/scripts/scaffold-consumer.sh` generates the boilerplate automatically.
`fsa-api/core/` is the reference implementation for how to extend UAA.
