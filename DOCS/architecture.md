# Architecture

## The three-org chain

fork-sync-all is the canonical automation control plane for the GitHub organisation chain
and the configured cross-forge mirror. The GitLab destinations are not interchangeable:
the current OSP mirroring configuration targets the `openos-project` root group.

```
Interested-Deving-1896/fork-sync-all (canonical control plane)
        │
        ▼
OpenOS-Project-OSP (GitHub mirror)
        │
        ├──► OpenOS-Project-Ecosystem-OOC (GitHub mirror)
        │
        └──► GitLab: openos-project/<subgroup>/<repo>
             default subgroup: ops

OOC GitLab namespace (separate destination; not wired by the default OSP mirror config)
openos-project-ooc-ecosystem/ops/fork-sync-all
```

| Location | Role / current configuration |
|---|---|
| `Interested-Deving-1896/fork-sync-all` (GitHub) | Canonical source and automation control plane |
| `OpenOS-Project-OSP` (GitHub) | Secondary mirror; receives pushes from the canonical org |
| `OpenOS-Project-Ecosystem-OOC` (GitHub) | Downstream ecosystem mirror; has separate upstream-return workflows |
| `gitlab.com/openos-project` | Configured GitLab destination for the OSP mirror script; unlisted repos fall back to `ops` |
| `gitlab.com/openos-project/ops/fork-sync-all` | Expected path for the OSP GitHub `fork-sync-all` repo under the current default subgroup rule; live project state has not been independently verified here |
| `gitlab.com/openos-project-ooc-ecosystem/ops/fork-sync-all` | User-identified OOC counterpart; separate namespace not covered by the current `config/gitlab-subgroups.yml` mapping and not the default destination |

The canonical repo owns automation policy and configuration. A GitLab repository existing at
a similar path does not, by itself, prove that it is actively mirrored or safe to treat as
a second control plane. Verify project existence, push/pull settings, branch history, and CI
ownership before changing either GitLab project.

---

## Data flow

### Inbound (upstream → I-D-1896)

Three paths bring upstream changes into `Interested-Deving-1896`:

1. **`sync-forks.yml`** (daily) — syncs all GitHub forks with their upstream parents
2. **`sync-registered-imports.yml`** (daily at 04:55 UTC) — re-syncs repos registered in
   `registered-imports.json`, including non-GitHub sources (GitLab, Bitbucket, Codeberg, etc.)
3. **`upstream-commits.yml` / `upstream-prs.yml`** (daily) — detects direct commits
   and open PRs in OSP/OOC that haven't been reflected upstream, and opens PRs in I-D-1896

### Outbound (canonical GitHub → GitHub mirrors and configured GitLab destination)

The GitHub mirror workflows publish to OSP and then OOC. The cross-forge push is a
separate workflow path: `.github/workflows/git-platform-sync.yml` is the active,
provider-neutral GitHub Actions workflow for Git-platform sync. The older
`sync-to-gitlab.yml` is a deprecated no-op stub, not the active GitLab push job.

```
mirror-to-osp.yml ──► mirror-osp-to-ooc.yml
                           │
                           └──► Git Platform Sync (direction=push)
                                  └──► GitLab openos-project/<subgroup>/<repo>
```

The current `scripts/mirror-osp-to-gitlab.sh` path is configured around the OSP
GitHub organisation and `openos-project` GitLab root group, with subgroup placement
from `config/gitlab-subgroups.yml` and an `ops` fallback. Do not infer that it also
publishes into `openos-project-ooc-ecosystem`; that namespace needs a separately
verified destination/configuration path before it can be described as an automated mirror.

`flush-lifecycle.yml` is the top-level entry point for a full pipeline run. It sets
`FLUSH_ACTIVE=true`, holds a sentinel runner slot, and coordinates the stages with quota
reservation and pause/resume at reset windows:

```
flush-lifecycle.yml
  └─ pre-flush-prep.yml    ← cancels stale runs, merges PRs, validates config
  └─ full-chain-flush.yml  ← all mirror + README + CI stages in order
  └─ post-flush-prep.yml   ← integrity checks and queue health verification
```

`full-chain-flush.yml` orchestrates the pipeline stages, but should be triggered via
`flush-lifecycle.yml` rather than directly, so the `FLUSH_ACTIVE` mutex and quota
reservation are active for the full run.

---

### GitLab subgroup placement

`config/gitlab-subgroups.yml` is the single source of truth for which repos go
into which GitLab subgroup. The 14 subgroups map to topic areas:

| Subgroup | Repos | Topic |
|---|---|---|
| `incus_deving` | 49 | Incus / container infrastructure |
| `yaml-tooling_deving` | 34 | YAML, CI, and tooling |
| `ops` | 30 | Operations and control plane |
| `agnostic-api_deving` | 29 | Unified Agnostic API — virtual filesystems, AI/LLM adapters, OS-compat layers |
| `penguins-eggs_deving` | 17 | penguins-eggs ecosystem |
| `linux-kernel_filesystem_deving` | 14 | Kernel and filesystem |
| `cachyos_deving` | 12 | CachyOS packages |
| `ai-agents_deving` | 10 | AI agent tooling |
| `accessibility_deving` | 9 | Screen readers, Braille, WCAG auditing, audio overviews |
| `git-management_deving` | 9 | Git tooling |
| `neon-deving` | 8 | KDE Neon ecosystem |
| `rust-systems_deving` | 2 | Rust system tools |
| `taubyte_deving` | 1 | Taubyte platform |
| `immutable-filesystem_deving` | 1 | Immutable Linux |

Repos not listed in any subgroup fall into the `ops` default subgroup.

---

## Quota management

Both `GH_TOKEN` and `SYNC_TOKEN` belong to the same GitHub user and share a
single 5000 req/hr REST bucket. The system has three layers of protection:

```
quota-reserve.yml  ──►  queue-manager.yml
  (every 30 min)          (every 30 min)
```

`quota-monitor.yml` is a separate manual-dispatch-only tool for waiting out quota
exhaustion. It is not part of the automatic quota management loop — see
[Operations](OPERATIONS.md) for when and how to use it.

| Layer | Threshold | Action |
|---|---|---|
| `quota-reserve` | < 1000 remaining | Cancels tier-4 (LOW) queued runs |
| `quota-reserve` | < 500 remaining | Cancels tier-3 (MEDIUM) queued runs |
| `queue-manager` | Run queued > 25 min | Evicts stale queued runs |
| `queue-manager` | Duplicate workflow | Keeps newest, cancels older |

Workflow priority tiers are defined in `config/workflow-priority-tiers.yml`.
Tier 1 (CRITICAL) runs are never cancelled. See [Operations](OPERATIONS.md) for
the full quota reference.

---

## Config files

| File | Purpose |
|---|---|
| `config/gitlab-subgroups.yml` | GitLab subgroup placement for 225 repos (14 subgroups) |
| `config/ona-projects.yml` | Ona project registry — maps repos to project IDs, environment classes, and tags |
| `config/workflow-priority-tiers.yml` | Priority tier for each workflow (used by queue-manager and quota-reserve) |
| `config/workflow-quota-costs.yml` | `min_quota` + cost tiers per workflow — source of truth for quota-reserve and pre-flight checks |
| `config/workflow-cost-profiles.yml` | Detailed REST/GraphQL/GitLab/AI call estimates per workflow (used by rate-limit-profile.sh) |
| `config/workflow-sync.yml` | GitHub ↔ GitLab CI job mapping (used by validate-workflow-guards) |
| `config/ota-registry.yml` | Repos opted in to the OTA update system |
| `config/ota-blocklist.yml` | Orgs/namespaces excluded from OTA by default |
| `config/template-manifest.yml` | Template sync profiles and file ownership |
| `config/template-consumers.yml` | Repos consuming each template profile |
| `registered-imports.json` | Upstream repos registered for ongoing sync |

---

## vendor/

`vendor/` contains third-party components that fork-sync-all hosts or deploys.
It is distinct from `scripts/` (first-party automation) and `config/` (config data).

Current components:

| Component | Description |
|---|---|
| `vendor/infra-dashboard` | Mirror-health and package-search SPA + Rust API backend |

All vendored components must be deployment-agnostic — no distro names, org-specific
URLs, or hardcoded deployment values. See [Contributing](contributing.md) for the
enforcement workflow.

---

## Token architecture

Two GitHub PATs are in active use, both owned by the same user (ID 202036334)
and sharing the same 5000 req/hr quota:

| Secret | Used by | Scope |
|---|---|---|
| `SYNC_TOKEN` | Most workflows | repo, workflow, admin:org |
| `GH_TOKEN` | Validation, README, config workflows | repo, workflow |

GitLab operations use `GITLAB_SYNC_TOKEN` (api, read/write_repository scope).

Token expiry is monitored weekly by `token-health.yml`. See [Token Rotation](https://github.com/Interested-Deving-1896/fork-sync-all/blob/main/AGENTS.md#token-rotation)
for rotation procedures.
