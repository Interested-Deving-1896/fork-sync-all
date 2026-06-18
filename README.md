# fork-sync-all

[![Built with Ona](https://ona.com/build-with-ona.svg)](https://app.ona.com/#https://github.com/OpenOS-Project-OSP/fork-sync-all)

Control plane for the `Interested-Deving-1896` GitHub org. Runs 121 GitHub Actions workflows that keep three GitHub orgs and a GitLab group in sync, manage READMEs and badges across OSP-bound repos, resolve CI failures, and maintain registered upstream imports.

<!-- FSA-COUNTS-START — updated 2026-06-18 by generate-workflow-triggers-doc.py -->
| | |
|---|---|
| Workflows | **127** |
| Registered imports | **156** |
| Template consumers | **80** |
| GitLab subgroups | **14** |
| GitLab repos mirrored | **225** |
<!-- FSA-COUNTS-END -->

---

## How it works

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
│          └──── upstream-commits / upstream-prs (OSP + OOC → I-D-1896) ─────┘
└─────────────────────────────────────────────────────────────────────────────┘

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
│  quota-reserve ──► queue-manager ──► rate-limit-rerun                       │
│                                           │                                 │
│                                    cancel-stale-runs                        │
│                                      quota-monitor                          │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│  OTA system (versioned updates for independent forks)                       │
│                                                                             │
│  ota-release ──► ota-deliver ──► opted-in forks (PR per fork)               │
│       ▲                                                                     │
│  semver tag push                                                            │
│                                                                             │
│  ota-reconcile (weekly) ──► path A: stamp · B: drift PR · C: quota PR      │
└─────────────────────────────────────────────────────────────────────────────┘
```

<!-- AI:start:what-it-does -->
fork-sync-all is the control plane for the `Interested-Deving-1896` GitHub org. It runs 121 GitHub Actions workflows that keep three GitHub orgs and a GitLab group in sync, manage READMEs and badges across ~49 OSP-bound repos, resolve CI failures, and maintain 156 registered upstream imports.

The mirror chain flows outward from `Interested-Deving-1896` → `OpenOS-Project-OSP` → `OpenOS-Project-Ecosystem-OOC` → `gitlab.com/openos-project`. Commits pushed directly to OSP or OOC are detected and opened as PRs back to `Interested-Deving-1896` so the source of truth stays in one place.

The OTA system delivers versioned updates to independent forks of fork-sync-all. When a semver tag is pushed, `ota-release.yml` assembles per-fork payloads and opens PRs in all opted-in repos. `ota-reconcile.yml` runs weekly as a fallback, detecting drift and quota-exhaustion gaps autonomously.
<!-- AI:end:what-it-does -->

---

## Documentation

| Resource | Description |
|---|---|
| [Full documentation](https://interested-deving-1896.github.io/fork-sync-all/) | Architecture, quota management, workflow reference, runbooks |
| [Workflow Triggers](docs/workflow-triggers.md) | All 121 workflows — schedules, triggers, synopses ([plain text](docs/workflow-triggers.txt)) |
| [OTA Reconcile](DOCS/ota-reconcile.md) | Hybrid A/B/C fallback layer for mirror-chain consumers |
| [OTA System](DOCS/ota-system.md) | OTA delivery architecture and opt-in guide |
| [AI Agent Costs](DOCS/ai-agent-costs.md) | OCU pricing, tokenizer reference, per-task estimates |
| [Quota Costs](DOCS/quota-costs.md) | Per-workflow REST call estimates (p50/p95) |
| [Workflow Scheduling](DOCS/workflow-scheduling.md) | Optimal dispatch windows, quota floors, EST/UTC timing |
| [Runbooks](DOCS/runbooks.md) | Incident response and operational procedures |

---

## Workflow groups

121 workflows across 13 functional groups. Full detail in [docs/workflow-triggers.md](docs/workflow-triggers.md).

| Group | Workflows | Description |
|---|---|---|
| [Mirror Chain](docs/workflow-triggers.md#mirror-chain) | 7 | Outward mirror: I-D-1896 → OSP → OOC → GitLab |
| [Fork & Import Sync](docs/workflow-triggers.md#fork--import-sync) | 10 | Upstream fork sync, registered imports, platform import |
| [README Management](docs/workflow-triggers.md#readme-management) | 7 | Create, update, badge, translate, validate READMEs |
| [CI & Failure Resolution](docs/workflow-triggers.md#ci--failure-resolution) | 7 | Rate-limit rerun, failure resolver, PR automation |
| [Full Pipeline](docs/workflow-triggers.md#full-pipeline) | 9 | pre-flush → full-chain-flush → post-flush + critical-deploy |
| [Quota & Queue Management](docs/workflow-triggers.md#quota--queue-management) | 4 | Reserve, dedup, monitor, cost registry |
| [OTA System](docs/workflow-triggers.md#ota-system) | 5 | Release delivery, reconcile, self-update, discover, opt-in |
| [Documentation & Publishing](docs/workflow-triggers.md#documentation--publishing) | 8 | mdBook, GitBook, NotebookLM, translate docs, triggers doc |
| [AI & Cost Tracking](docs/workflow-triggers.md#ai--cost-tracking) | 2 | Session cost log, weekly price sync |
| [Maintenance & Housekeeping](docs/workflow-triggers.md#maintenance--housekeeping) | 10 | Config validation, cleanup, token rotation, dep updates |
| [OSP-Bound Repo Management](docs/workflow-triggers.md#osp-bound-repo-management) | 3 | Add mirror repo, CI status, setup OSP mirrors |
| [GitLab Sync](docs/workflow-triggers.md#gitlab-sync) | 2 | Push/pull sync with GitLab |
| [Utility / On-Demand](docs/workflow-triggers.md#utility--on-demand) | 45 | Manual and specialised workflows |

---

## Key config files

| File | Purpose |
|---|---|
| `config/gitlab-subgroups.yml` | Single source of truth for GitLab subgroup placement |
| `config/workflow-quota-costs.yml` | Per-workflow REST call cost estimates — drives quota pre-flight and `quota-reserve.yml` |
| `config/workflow-priority-tiers.yml` | Cancellation priority (Tier 1 = never cancel, Tier 4 = cancel first) |
| `config/workflow-sync.yml` | Which workflows have GitLab CI counterparts |
| `config/template-manifest.yml` | Profile definitions for template sync (full / mirror / infra-core / standalone) |
| `config/template-consumers.yml` | 80 repos that receive template updates via `sync-template.yml` |
| `config/ota-registry.yml` | Opted-in forks receiving OTA updates |
| `config/ota-blocklist.yml` | Orgs/profiles excluded from OTA delivery by default |
| `config/agent-cost-profiles.yml` | Machine-readable AI agent cost profiles (8 variants, 10 complexity tiers) |
| `registered-imports.json` | 156 upstream repos kept in ongoing sync |

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
| `NOTEBOOKLM_AUTH_JSON` | `generate-notebooklm.yml` | Short-lived auth state, rotated weekly by `refresh-notebooklm-auth.yml` |
| `ACTIVITYSMITH_API_KEY` | `full-chain-flush.yml` | Optional — live activity tracking; skipped if unset |
| `SYNC_IN_SERVER_URL` | `sync-in.yml` | URL of the local sync-in server instance |

```bash
gh secret set <SECRET_NAME> --repo Interested-Deving-1896/fork-sync-all
```

---

## Rate limits

Both `SYNC_TOKEN` and `GH_SYNC_TOKEN` belong to the same user and share the same 5,000 req/hr REST bucket. Treat them as one pool. `raw.githubusercontent.com` fetches do **not** count against the quota.

| API | Limit | Reset |
|---|---|---|
| GitHub REST | 5,000 req/hr per token | Top of the hour |
| GitHub GraphQL | 5,000 pts/hr (counts as 1 REST call) | Top of the hour |
| GitHub Models | Varies by model | Per-minute window |
| GitLab REST | 2,000 req/min per token | Per-minute window |

`quota-reserve.yml` cancels low-priority queued runs when remaining quota drops below 1,000. Check current quota:

```bash
curl -sf -H "Authorization: token $SYNC_TOKEN" \
  "https://api.github.com/rate_limit" | \
  python3 -c "
import sys, json, datetime
d = json.load(sys.stdin)['resources']['core']
reset = datetime.datetime.utcfromtimestamp(d['reset']).strftime('%H:%M UTC')
print(f'remaining={d[\"remaining\"]}  resets={reset}')
"
```

---

## GitLab subgroups

14 subgroups under `gitlab.com/openos-project`, 225 repos mirrored. Assignments are in `config/gitlab-subgroups.yml`.

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

---

<!-- AI:start:architecture -->
## Architecture

fork-sync-all is structured as a hub-and-spoke control plane. All automation lives in this repo; consumer repos receive only the files they need via `sync-template.yml`. 121 workflows across 13 functional groups: mirror chain, full pipeline, quota/queue management, OTA system, and supporting layers.

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

**OTA system** (versioned updates for independent forks):
- Push a semver tag → `ota-release.yml` delivers to all opted-in forks via PR
- `ota-reconcile.yml` runs weekly as a fallback: path A (stamp), B (drift PR), C (quota-recovery PR)
- Mirror-chain repos are excluded from OTA delivery by default but covered by reconcile

**Quota management** runs on two axes:
- `queue-manager.yml` deduplicates queued runs every 30 min
- `quota-reserve.yml` cancels low-priority runs when the REST bucket drops below 1,000
- Both read `config/workflow-priority-tiers.yml` at runtime — no script edits needed when adding workflows
<!-- AI:end:architecture -->

---

<!-- AI:start:ci -->
## CI

Every push and PR runs `validate-config.yml`, which gates on:

1. **YAML parse** — all 121 workflow files parse cleanly
2. **Workflow guards** — `workflow_run` trigger names match real workflows; quota-cost and priority-tier entries are consistent
3. **Shell syntax** — `bash -n` on all scripts
4. **Schema validation** — `gavi` validates all workflows against the GitHub Actions JSON schema
5. **Config validators** — `gitlab-subgroups.yml`, `registered-imports.json`, `template-manifest.yml`, `workflow-priority-tiers.yml`, `workflow-cost-profiles.yml`
6. **AgentShield** — AI agent config security scan

The required status check is `CI Required` (a gate job that always runs and reflects all filtered outcomes).
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
