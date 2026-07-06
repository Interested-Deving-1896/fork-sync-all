# fork-sync-all

[![Built with Ona](https://ona.com/build-with-ona.svg)](https://app.ona.com/#https://github.com/OpenOS-Project-OSP/fork-sync-all) [![Open Collective](https://img.shields.io/opencollective/all/fork-sync-all?label=supporters&logo=opencollective&style=flat-square)](https://opencollective.com/fork-sync-all)

<!-- FSA-MOTTO-START -->
> When Git Platforms Give You Anxiety Attacks, Who Are You Going To Call? Fork-Sync-All!
<!-- FSA-MOTTO-END -->

Control plane for the `Interested-Deving-1896` GitHub org. Runs 147 GitHub Actions workflows that keep three GitHub orgs and two GitLab groups in sync, manage READMEs and badges across OSP-bound repos, resolve CI failures, and maintain registered upstream imports.

<!-- FSA-COUNTS-START — updated 2026-07-04 by generate-workflow-triggers-doc.py -->
| | |
|---|---|
| Workflows | **180** |
| Registered imports | **157** |
| Template consumers | **82** |
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
│  flush-lifecycle ──► pre-flush-prep ──► full-chain-flush (25 stages) ──► post-flush-prep │
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
This project automates repository management tasks for git-based platforms, addressing challenges in maintaining forks, synchronizing changes, and managing organizational repositories. It provides workflows for fork synchronization, upstream tracking, mirroring, README generation, badge injection, and release management. It is used by developers and organizations to streamline version control and ensure consistency across repositories.
<!-- AI:end:what-it-does -->

---

## Documentation

| Resource | Description |
|---|---|
| [Full documentation](https://interested-deving-1896.github.io/fork-sync-all/) | Architecture, quota management, workflow reference, runbooks |
| [Workflow Triggers](DOCS/workflow-triggers.md) | All 185 workflows — schedules, triggers, synopses ([plain text](DOCS/workflow-triggers.txt) · [published](https://interested-deving-1896.github.io/fork-sync-all/workflow-triggers.html)) |
| [OTA Reconcile](DOCS/ota-reconcile.md) | Hybrid A/B/C fallback layer for mirror-chain consumers |
| [OTA System](DOCS/ota-system.md) | OTA delivery architecture and opt-in guide |
| [AI Agent Costs](DOCS/ai-agent-costs.md) | OCU pricing, tokenizer reference, per-task estimates |
| [Quota Costs](DOCS/quota-costs.md) | Per-workflow REST call estimates (p50/p95) |
| [Workflow Scheduling](DOCS/workflow-scheduling.md) | Optimal dispatch windows, quota floors, EST/UTC timing |
| [Runbooks](DOCS/runbooks.md) | Incident response and operational procedures |

---

## Workflow groups

<!-- FSA-GROUPS-START — updated 2026-07-04 by generate-workflow-triggers-doc.py -->
158 workflows across 20 functional groups. Full detail in [DOCS/workflow-triggers.md](DOCS/workflow-triggers.md).

| Group | Workflows | Description |
|---|---|---|
| [Accessibility](DOCS/workflow-triggers.md#accessibility) | 1 | CODEOWNERS coverage, screen-reader scan, WCAG audit, audio overview, Braille output |
| [AI & Cost Tracking](DOCS/workflow-triggers.md#ai--cost-tracking) | 4 | Session cost log, weekly price sync |
| [BDFS / Filesystem Workspace](DOCS/workflow-triggers.md#bdfs--filesystem-workspace) | 5 | DwarFS/BTRFS workspace dev and packaging |
| [Bugzilla Integration](DOCS/workflow-triggers.md#bugzilla-integration) | 1 | Sync commits/PRs to Bugzilla, milestone shipping |
| [Build & Release](DOCS/workflow-triggers.md#build--release) | 10 | Build, checks, release, kernel content, arch config |
| [CI & Failure Resolution](DOCS/workflow-triggers.md#ci--failure-resolution) | 7 | Rate-limit rerun, failure resolver, runner status |
| [Documentation & Publishing](DOCS/workflow-triggers.md#documentation--publishing) | 9 | mdBook, GitBook, NotebookLM, translate docs, triggers doc |
| [Fork & Import Sync](DOCS/workflow-triggers.md#fork--import-sync) | 20 | Upstream fork sync, registered imports, platform import |
| [Full Pipeline](DOCS/workflow-triggers.md#full-pipeline) | 8 | pre-flush → full-chain-flush → post-flush + critical-deploy |
| [Git Platform Sync](DOCS/workflow-triggers.md#git-platform-sync) | 5 | Bidirectional push/pull sync with GitLab |
| [Infrastructure & Environment](DOCS/workflow-triggers.md#infrastructure--environment) | 4 | Dev container SDK, Incus, FSA API |
| [Maintenance & Housekeeping](DOCS/workflow-triggers.md#maintenance--housekeeping) | 16 | Config validation, cleanup, token rotation, dep updates |
| [Mirror Chain](DOCS/workflow-triggers.md#mirror-chain) | 14 | Outward mirror: I-D-1896 → OSP → OOC → GitLab |
| [OSP-Bound Repo Management](DOCS/workflow-triggers.md#osp-bound-repo-management) | 7 | Add mirror repo, CI status, setup OSP mirrors |
| [OTA System](DOCS/workflow-triggers.md#ota-system) | 5 | Release delivery, reconcile, self-update, discover, opt-in |
| [PR Governance & Trust](DOCS/workflow-triggers.md#pr-governance--trust) | 10 | Vouch, PR gate, labeler, auto-merge, rebase |
| [Quota & Queue Management](DOCS/workflow-triggers.md#quota--queue-management) | 5 | Reserve, dedup, monitor, cost registry |
| [README Management](DOCS/workflow-triggers.md#readme-management) | 10 | Create, update, badge, translate, validate READMEs |
| [Security & Compliance](DOCS/workflow-triggers.md#security--compliance) | 6 | SBOM, CodeQL, vendor audit, arch audit, pin workflows |
| [Utility / On-Demand](DOCS/workflow-triggers.md#utility--on-demand) | 11 | Manual and specialised workflows |
<!-- FSA-GROUPS-END -->

---

## Key config files

| File | Purpose |
|---|---|
| `config/agent-cost-profiles.yml` | Machine-readable AI agent cost profiles (8 variants, 10 complexity tiers) |
| `config/gitlab-subgroups.yml` | Single source of truth for GitLab subgroup placement |
| `config/ota-blocklist.yml` | Orgs/profiles excluded from OTA delivery by default |
| `config/ota-registry.yml` | Opted-in forks receiving OTA updates |
| `config/template-consumers.yml` | 80 repos that receive template updates via `sync-template.yml` |
| `config/template-manifest.yml` | Profile definitions for template sync (full / mirror / infra-core / standalone) |
| `config/workflow-priority-tiers.yml` | Cancellation priority (Tier 1 = never cancel, Tier 4 = cancel first) |
| `config/workflow-quota-costs.yml` | Per-workflow REST call cost estimates — drives quota pre-flight and `quota-reserve.yml` |
| `config/workflow-sync.yml` | Which workflows have GitLab CI counterparts |
| `registered-imports.json` | 156 upstream repos kept in ongoing sync |

---

## Secrets

| Secret | Used by | Notes |
|---|---|---|
| `ACTIVITYSMITH_API_KEY` | `full-chain-flush.yml` | Optional — live activity tracking; skipped if unset |
| `ADD_MIRROR_REPO_SYNC` | `add-mirror-repo.yml` | Scoped PAT for repo creation |
| `BITBUCKET_TOKEN` | `import-repo.yml`, `sync-registered-imports.yml` | Bitbucket app password (private repos only) |
| `GH_SYNC_TOKEN` | GitLab CI `sync-from-gitlab` job | Same PAT stored as a GitLab CI variable |
| `GITEA_TOKEN` | `import-repo.yml`, `sync-registered-imports.yml` | Gitea/Codeberg PAT (private repos only) |
| `GITLAB_SYNC_TOKEN` | `mirror-osp-to-gitlab.yml`, post-flush verification | GitLab PAT for mirror operations |
| `GITLAB_TOKEN` | GitLab workflows | GitLab PAT — `api` + `write_repository` on `openos-project` |
| `NOTEBOOKLM_AUTH_JSON` | `generate-notebooklm.yml` | Short-lived auth state, rotated weekly by `refresh-notebooklm-auth.yml` |
| `OSP_ADMIN_TOKEN` | OSP org admin operations | PAT with `admin:org` on `OpenOS-Project-OSP` |
| `SOURCEHUT_TOKEN` | `import-repo.yml` | Sourcehut PAT (private repos only) |
| `SYNC_IN_SERVER_URL` | `sync-in.yml` | URL of the local sync-in server instance |
| `SYNC_TOKEN` | All workflows | GitHub PAT — `repo` + `workflow` + `admin:org` scopes |

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
| `accessibility_deving` | 9 | Screen readers, Braille, WCAG auditing, audio overviews |
| `agnostic-api_deving` | 29 | Unified Agnostic API — virtual filesystems, AI/LLM adapters, OS-compat layers |
| `ai-agents_deving` | 10 | AI agent frameworks and tools |
| `cachyos_deving` | 12 | CachyOS distro packages |
| `git-management_deving` | 9 | Git tooling and org management |
| `immutable-filesystem_deving` | 1 | Immutable filesystem projects |
| `incus_deving` | 49 | Incus container/VM tooling |
| `linux-kernel_filesystem_deving` | 14 | Kernel and filesystem repos |
| `neon-deving` | 8 | KDE Neon repos |
| `ops` | 30 | Infrastructure and org management tooling |
| `penguins-eggs_deving` | 17 | penguins-eggs distro tools |
| `rust-systems_deving` | 2 | Rust systems programming |
| `taubyte_deving` | 1 | Taubyte protocol |
| `yaml-tooling_deving` | 34 | YAML tools, linters, schema validators, GH Actions tooling |

---

<!-- AI:start:architecture -->
The project consists of several key components designed for managing git repositories and organizations across multiple platforms. It automates tasks such as fork synchronization, README generation, mirroring, badge injection, upstream tracking, and release management. The architecture is built around modular workflows, primarily written in Shell, which are executed via CI/CD pipelines. These workflows are defined in YAML files located in the `.github/workflows` and `.gitlab` directories, enabling platform-agnostic operations.

The repository is organized as follows:

```plaintext
.
├── .github/               # GitHub-specific configurations and workflows
│   └── workflows/         # GitHub Actions workflow definitions
├── .gitlab/               # GitLab-specific configurations and workflows
├── assets/                # Static assets for documentation and automation
├── config/                # Configuration files for various tools and workflows
├── data/                  # Data files used by workflows and scripts
├── dep-graph/             # Dependency graph generation scripts
├── docs/                  # Project documentation
├── .devcontainer/         # Development container configuration
├── .dotdrop/              # Dotfiles management
├── .ota/                  # Over-the-air update configurations
├── .reuse/                # Licensing compliance files
├── AGENTS.md              # Documentation for agent-based workflows
├── CHANGELOG.md           # Project changelog
├── CONTRIBUTING.md        # Contribution guidelines
├── LICENSE                # License file
├── README.md              # Project overview and usage instructions
└── book.toml              # Configuration for documentation generation
```

Workflows are the core of the project, enabling tasks like repository synchronization (`sync-forks.yml`), badge injection (`inject-badges.yml`), and upstream tracking (`sync-upstream-mirrors.yml`). These workflows interact with git-based platforms via APIs and are triggered by events or schedules. Configuration files and scripts in the `config/` and `data/` directories provide customization and support for these workflows.
<!-- AI:end:architecture -->

---

<!-- AI:start:ci -->
- **`ci.yaml`**: Executes the main CI pipeline, including linting, testing, and build steps. No secrets required.
- **`codeql-analysis.yml`**: Runs CodeQL for static code analysis to detect vulnerabilities. Requires `GH_TOKEN` secret.
- **`sync-forks.yml`**: Synchronizes forked repositories with their upstream counterparts. Requires `GH_TOKEN` secret.
- **`inject-badges.yml`**: Updates repository README files with status badges. Requires `GH_TOKEN` secret.
- **`mirror-orgs-full.yml`**: Mirrors all repositories in an organization across platforms. Requires `GH_TOKEN` and `MIRROR_TOKEN` secrets.
- **`update-readmes.yml`**: Automates README generation and updates. Requires `GH_TOKEN` secret.
- **`pr-gate.yml`**: Validates pull requests with tests and linting before merge. No secrets required.
- **`auto-merge-prs.yml`**: Automatically merges pull requests meeting predefined criteria. Requires `GH_TOKEN` secret.
- **`cleanup-branches.yml`**: Deletes stale branches from repositories. Requires `GH_TOKEN` secret.
- **`validate-config.yml`**: Validates configuration files for syntax and schema compliance. No secrets required.
- **`mirror-releases.yml`**: Mirrors release assets across platforms. Requires `GH_TOKEN` and `MIRROR_TOKEN` secrets.
- **`sync-upstream-mirrors.yml`**: Synchronizes upstream mirrors for repositories. Requires `GH_TOKEN` and `MIRROR_TOKEN` secrets.
- **`check-ci.yml`**: Ensures CI workflows are functioning correctly. No secrets required.
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
[@Interested-Deving-1896](https://github.com/Interested-Deving-1896): 480 commits  
[@github-actions[bot]](https://github.com/github-actions[bot]): 78 commits  
[@actions-user](https://github.com/actions-user): 7 commits  
[@dependabot[bot]](https://github.com/dependabot[bot]): 6 commits  
[@web-flow](https://github.com/web-flow): 5 commits  

*Note: This repository may be a mirror. Please refer to the upstream source for additional context.*
<!-- AI:end:contributors -->

---

## License

<!-- AI:start:license -->
[GPL-3.0](https://github.com/Interested-Deving-1896/fork-sync-all/blob/main/LICENSE) © 2026 [Interested-Deving-1896](https://github.com/Interested-Deving-1896)
<!-- AI:end:license -->
