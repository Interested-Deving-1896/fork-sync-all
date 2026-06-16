# fork-sync-all

[![Built with Ona](https://ona.com/build-with-ona.svg)](https://app.ona.com/#https://github.com/OpenOS-Project-OSP/fork-sync-all)

Sync and mirror infrastructure for the three-org chain:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Mirror chain (outward, every 6h)                                           │
│                                                                             │
│  Interested-Deving-1896 ──► OpenOS-Project-OSP                              │
│          ▲                         │                                        │
│          │                         ▼                                        │
│          │              OpenOS-Project-Ecosystem-OOC                        │
│          │                         │                                        │
│          │                         ▼                                        │
│          │                  GitLab openos-project                           │
│          │             (14 subgroups, 225 repos mirrored)                   │
│          │                                                                  │
│          └──── upstream-commits / upstream-prs (OSP + OOC → I-D-1896) ──────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│  Full pipeline (manual / monthly)                                           │
│                                                                             │
│  pre-flush-prep ──► full-chain-flush (18 stages) ──► post-flush-prep        │
│       │                      │                             │                │
│  QUOTA_SNAPSHOT          QUOTA_SNAPSHOT               QUOTA_SNAPSHOT        │
│  (chain entry)           (chain start)                (chain exit)          │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│  Quota & queue management (automatic, every 30 min)                         │
│                                                                             │
│  quota-reserve ──► queue-manager ──► runner-status                          │
│                         │                                                   │
│                  rate-limit-rerun ──► cancel-stale-runs                     │
│                    (every 4h)         quota-monitor                         │
└─────────────────────────────────────────────────────────────────────────────┘
```

<!-- AI:start:what-it-does -->
fork-sync-all is the control plane for the `Interested-Deving-1896` GitHub org. It runs 112 GitHub Actions workflows that keep three GitHub orgs and a GitLab group in sync, manage READMEs and badges across ~49 OSP-bound repos, resolve CI failures, and maintain 152 registered upstream imports.

The mirror chain flows outward from `Interested-Deving-1896` → `OpenOS-Project-OSP` → `OpenOS-Project-Ecosystem-OOC` → `gitlab.com/openos-project`. Commits pushed directly to OSP or OOC are detected and opened as PRs back to `Interested-Deving-1896` so the source of truth stays in one place.
<!-- AI:end:what-it-does -->

---

## Documentation

- [Full documentation](https://interested-deving-1896.github.io/fork-sync-all/) — architecture, quota management, workflow reference, runbooks
- [Workflow Triggers](docs/workflow-triggers.md) — all 112 workflows, their schedules, and what else triggers them ([plain text](docs/workflow-triggers.txt))
- [Workflow Scheduling Guide](DOCS/workflow-scheduling.md) — optimal dispatch windows, quota floors, EST/UTC timing reference
- [Quota Costs](DOCS/quota-costs.md) — per-workflow REST call estimates (p50/p95)

---

## Workflows

112 workflows across 17 GitLab-paired and 95 GitHub-only. Key groups:

### Mirror chain

| Workflow | Schedule (UTC) | What it does |
|---|---|---|
| `mirror-to-osp.yml` | Every 6h at :13 | Mirrors `Interested-Deving-1896` → `OpenOS-Project-OSP` |
| `mirror-osp-to-ooc.yml` | Every 6h at :45 | Mirrors `OpenOS-Project-OSP` → `OpenOS-Project-Ecosystem-OOC` |
| `mirror-osp-to-gitlab.yml` | Daily 01:23 | Mirrors `OpenOS-Project-OSP` → GitLab `openos-project` |
| `mirror-orgs-full.yml` | Daily 02:17 | Full org mirror (all branches, tags, refs) |
| `mirror-releases.yml` | Every 12h at :03 | Mirrors GitHub Releases + assets across all three orgs |
| `mirror-artifacts.yml` | Daily 02:10 | Mirrors Flatpak, RPM, and container artifacts |

### Fork & import sync

| Workflow | Schedule (UTC) | What it does |
|---|---|---|
| `sync-forks.yml` | Daily 06:07 | Syncs all `Interested-Deving-1896` forks with their upstreams |
| `sync-registered-imports.yml` | Daily 04:55 | Re-syncs all 152 repos in `registered-imports.json` |
| `sync-pieroproietti-forks.yml` | Daily 01:07 | Fast-path sync for pieroproietti forks |
| `upstream-prs.yml` | Daily 03:33 | Opens PRs for OSP/OOC commits not in `Interested-Deving-1896` |
| `upstream-commits.yml` | Daily 03:47 | Detects direct OSP/OOC commits; opens reconciliation PRs |
| `import-repo.yml` | Manual | Imports any git repo from any platform |

### README, badges & content

| Workflow | Schedule (UTC) | What it does |
|---|---|---|
| `update-readmes.yml` | Daily 03:15 | Regenerates AI-owned README sections across OSP-bound repos |
| `create-readmes.yml` | Daily 07:08 | Creates READMEs for repos that have none |
| `inject-badges.yml` | Every 2 days 08:15 | Injects Built-with-Ona badges |
| `translate-readmes.yml` | Every 2 days 10:43 | Translates READMEs to French |
| `reconcile-org-refs.yml` | Every 2 days 05:50 | Rewrites org names in file content across all three orgs |

### Full pipeline

| Workflow | Schedule (UTC) | What it does |
|---|---|---|
| `pre-flush-prep.yml` | Manual | Clears queue, merges PRs, validates config, writes entry `QUOTA_SNAPSHOT`, then dispatches flush |
| `full-chain-flush.yml` | Monthly 05:17 / manual | Master orchestrator — runs the full 18-stage pipeline in sequence; writes `QUOTA_SNAPSHOT` at start |
| `post-flush-prep.yml` | After flush / manual | End-to-end verification (mirror integrity, CI, badge check); writes exit `QUOTA_SNAPSHOT` |

### CI, quota & queue management

| Workflow | Schedule (UTC) | What it does |
|---|---|---|
| `check-ci.yml` | Daily 09:05 | Checks CI status across all configured targets (GitHub + GitLab) |
| `resolve-ci.yml` | Daily 07:43 | AI-assisted CI failure resolver across all targets |
| `queue-manager.yml` | Every 30 min | Deduplicates queued runs; evicts runs queued > 25 min |
| `quota-reserve.yml` | Every 30 min | Cancels low-priority runs when quota < 1,000 |
| `runner-status.yml` | Every hour at :10 | Runner utilisation and queue depth report; flags critical backlog |
| `rate-limit-rerun.yml` | Every 4h at :05 | Re-triggers workflows that failed due to rate limiting |
| `cancel-stale-runs.yml` | After rate-limit-rerun | Clears post-outage run pile-up immediately after reruns are dispatched |
| `rate-limit-status.yml` | Manual / after rerun | Snapshots quota across all platforms (GitHub REST/GraphQL, GitLab, Models) |
| `validate-config.yml` | On push / PR | Validates all config files; runs AgentShield security scan |
| `full-audit.yml` | Weekly Monday 04:00 | 20-check structural audit of workflows, configs, and wiring |

### Infrastructure & maintenance

| Workflow | Schedule (UTC) | What it does |
|---|---|---|
| `cleanup-branches.yml` | Monthly 04:29 | Deletes branches merged into main across the org |
| `update-infra-deps.yml` | Weekly Monday 06:11 | Opens PRs for outdated Actions versions, runners, Node/Python |
| `token-health.yml` | Weekly Monday 09:24 | Checks PAT expiry; opens an issue at 45 days out |

---

## Secrets

| Secret | Used by | Notes |
|---|---|---|
| `SYNC_TOKEN` | All workflows | GitHub PAT — `repo` + `workflow` + `admin:org` scopes |
| `GITLAB_TOKEN` | GitLab workflows | GitLab PAT — `api` + `write_repository` on `openos-project` |
| `GITLAB_SYNC_TOKEN` | `mirror-osp-to-gitlab.yml`, post-flush verification | GitLab PAT for mirror operations |
| `GH_SYNC_TOKEN` | GitLab CI `sync-from-gitlab` job | Same PAT stored as a GitLab CI variable |
| `ADD_MIRROR_REPO_SYNC` | `add-mirror-repo.yml` | Scoped PAT for repo creation |
| `OSP_ADMIN_TOKEN` | OSP org admin operations | PAT with `admin:org` on `OpenOS-Project-OSP` |
| `BITBUCKET_TOKEN` | `import-repo.yml`, `sync-registered-imports.yml` | Bitbucket app password (private repos only) |
| `GITEA_TOKEN` | `import-repo.yml`, `sync-registered-imports.yml` | Gitea/Codeberg PAT (private repos only) |
| `SOURCEHUT_TOKEN` | `import-repo.yml` | Sourcehut PAT (private repos only) |
| `ACTIVITYSMITH_API_KEY` | `full-chain-flush.yml` | Optional — live activity tracking; skipped if unset |
| `SYNC_IN_SERVER_URL` | `sync-in.yml` | URL of the local sync-in server instance |

To add a missing secret:

```bash
gh secret set <SECRET_NAME> --repo Interested-Deving-1896/fork-sync-all
```

---

## Registered Imports

`registered-imports.json` tracks 152 repos imported via `import-repo.yml` with `ongoing_sync` enabled. `sync-registered-imports.yml` re-pulls each source daily at 04:55 UTC.

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

Both `SYNC_TOKEN` and `GH_SYNC_TOKEN` belong to the same user and share the same 5,000 req/hr REST bucket. Treat them as one pool.

| API | Limit | Reset | Notes |
|---|---|---|---|
| GitHub REST | 5,000 req/hr per token | Top of the hour | `X-RateLimit-Reset` header |
| GitHub GraphQL | 5,000 pts/hr (counts as 1 REST call) | Top of the hour | Preferred for bulk repo queries |
| GitHub Models | Varies by model | Per-minute window | `Retry-After` header |
| GitLab REST | 2,000 req/min per token | Per-minute window | `RateLimit-Reset` header |

`raw.githubusercontent.com` fetches do **not** count against the quota.

All scripts retry up to 3 times with reset-aware backoff on 403/429. The `quota-reserve.yml` workflow cancels low-priority queued runs when remaining quota drops below 1,000. Check current quota:

```bash
curl -sf -H "Authorization: token $SYNC_TOKEN" \
  "https://api.github.com/rate_limit" | \
  python3 -c "
import sys,json,datetime
d=json.load(sys.stdin)['resources']['core']
print(f\"remaining={d['remaining']}  resets={datetime.datetime.utcfromtimestamp(d['reset']).strftime('%H:%M UTC')}\")
"
```

**Workflows most likely to hit limits:** `reconcile-org-refs.yml` (reads every file in every repo), `check-ci.yml` (scans all repos across three orgs), and `resolve-ci.yml` (AI-assisted analysis). These run in their own concurrency groups so they don't compound each other.

---

## GitLab subgroups

14 subgroups under `gitlab.com/openos-project`, 225 repos mirrored:

| Subgroup | Repos | Focus |
|---|---|---|
| `incus_deving` | 49 | Incus container/VM tooling |
| `yaml-tooling_deving` | 34 | YAML tools, linters, schema validators, GH Actions tooling |
| `ops` | 30 | Infrastructure and org management tooling |
| `agnostic-api_deving` | 29 | Unified Agnostic API — virtual filesystems, AI/LLM adapters, OS-compat layers |
| `penguins-eggs_deving` | 17 | penguins-eggs distro tools |
| `linux-kernel_filesystem_deving` | 14 | Kernel and filesystem repos |
| `cachyos_deving` | 12 | CachyOS distro packages |
| `ai-agents_deving` | 10 | AI agent frameworks and tools |
| `accessibility_deving` | 9 | Screen readers, Braille, WCAG auditing, audio overviews |
| `git-management_deving` | 9 | Git tooling and org management |
| `neon-deving` | 8 | KDE Neon repos |
| `rust-systems_deving` | 2 | Rust systems programming |
| `taubyte_deving` | 1 | Taubyte protocol |
| `immutable-filesystem_deving` | 1 | Immutable filesystem projects |

Subgroup IDs and repo assignments are in `config/gitlab-subgroups.yml`.

---

<!-- AI:start:architecture -->
## Architecture

fork-sync-all is structured as a hub-and-spoke control plane. All automation lives in this repo; consumer repos receive only the files they need via `sync-template.yml`. 112 workflows across three functional layers: mirror chain, full pipeline, and quota/queue management.

**Mirror chain** (outward flow, runs every 6h):
```
Interested-Deving-1896  ──[mirror-to-osp]──►  OpenOS-Project-OSP
                                                      │
                              ──[mirror-osp-to-ooc]──►  OpenOS-Project-Ecosystem-OOC
                                                      │
                              ──[mirror-osp-to-gitlab]──►  gitlab.com/openos-project
```

**Feedback loop** (inward flow, runs daily):
- `upstream-prs.yml` + `upstream-commits.yml` detect changes on OSP/OOC and open PRs back to `Interested-Deving-1896`
- `git-platform-sync.yml` pulls from GitLab back to GitHub

**Key config files:**
- `config/gitlab-subgroups.yml` — single source of truth for GitLab subgroup placement
- `config/workflow-quota-costs.yml` — per-workflow REST call cost estimates (drives quota pre-flight)
- `config/workflow-priority-tiers.yml` — cancellation priority (Tier 1 = never cancel, Tier 4 = cancel first)
- `config/workflow-sync.yml` — which workflows have GitLab CI counterparts
- `registered-imports.json` — 152 upstream repos kept in ongoing sync

**Quota management** runs on two axes: `queue-manager.yml` deduplicates queued runs every 30 min; `quota-reserve.yml` cancels low-priority runs when the REST bucket drops below 1,000. Both read `config/workflow-priority-tiers.yml` at runtime — no script edits needed when adding new workflows.
<!-- AI:end:architecture -->

---

<!-- AI:start:ci -->
## CI

Every push and PR runs `validate-config.yml`, which gates on:

1. **YAML parse** — all 112 workflow files parse cleanly
2. **Workflow guards** — `rate_limit_rerun` inputs have job-level guards; `workflow_run` trigger names match real workflows; quota-cost and priority-tier entries are consistent
3. **Shell syntax** — `bash -n` on all scripts
4. **Schema validation** — `gavi` validates all workflows against the GitHub Actions JSON schema
5. **Config validators** — `gitlab-subgroups.yml`, `registered-imports.json`, `template-manifest.yml`, `workflow-priority-tiers.yml`, `workflow-cost-profiles.yml`
6. **AgentShield** — AI agent config security scan (opt-in via `ANTHROPIC_API_KEY` secret)

The required status check is `CI Required` (a gate job that always runs and reflects all filtered outcomes). `full-audit.yml` runs 20 deeper checks weekly on Monday at 04:00 UTC.
<!-- AI:end:ci -->

---

## Origins

<!-- AI:start:origins -->

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
| [registered-imports.json](https://github.com/Interested-Deving-1896/fork-sync-all/blob/main/registered-imports.json) | Registered ongoing-sync imports |
| [dep-graph/origins.md](https://github.com/Interested-Deving-1896/fork-sync-all/blob/main/dep-graph/origins.md) | Dependency graph (Markdown table) |
| [.gitlab/merge_request_templates/Default.md](https://github.com/Interested-Deving-1896/fork-sync-all/blob/main/.gitlab/merge_request_templates/Default.md) | GitLab MR template |
| [config/gitlab-subgroups.yml](https://github.com/Interested-Deving-1896/fork-sync-all/blob/main/config/gitlab-subgroups.yml) | GitLab subgroup map |
<!-- AI:end:resources -->

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

## Contributors

<!-- AI:start:contributors -->
_Contributors pending._
<!-- AI:end:contributors -->

---

## License

<!-- AI:start:license -->
[GPL-3.0](https://github.com/Interested-Deving-1896/fork-sync-all/blob/main/LICENSE) © 2026 [Interested-Deving-1896](https://github.com/Interested-Deving-1896)
<!-- AI:end:license -->
