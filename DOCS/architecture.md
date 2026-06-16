# Architecture

## The three-org chain

fork-sync-all is the control plane for a three-organisation mirror chain on GitHub,
with a fourth leg into GitLab:

```
Interested-Deving-1896  ──►  OpenOS-Project-OSP
        ▲                           │
        │                           ▼
        │              OpenOS-Project-Ecosystem-OOC
        │                           │
        │                           ▼
        │                  GitLab openos-project
        │             (14 subgroups, 225 repos mirrored)
        │
        └──── upstream-commits / upstream-prs (OSP + OOC → I-D-1896)
```

| Org | Role |
|---|---|
| `Interested-Deving-1896` | Primary — forks live here, all automation runs here |
| `OpenOS-Project-OSP` | Secondary mirror — receives pushes from I-D-1896 |
| `OpenOS-Project-Ecosystem-OOC` | Tertiary mirror — receives pushes from OSP |
| `gitlab.com/openos-project` | GitLab mirror — receives pushes from OSP via GitLab CI |

All automation runs in `Interested-Deving-1896/fork-sync-all`. The other orgs are
passive recipients — they do not run their own automation except for the GitLab CI
mirror job that pushes back to GitLab.

---

## Data flow

### Inbound (upstream → I-D-1896)

Three paths bring upstream changes into `Interested-Deving-1896`:

1. **`sync-forks.yml`** (daily) — syncs all GitHub forks with their upstream parents
2. **`sync-registered-imports.yml`** (daily at 04:55 UTC) — re-syncs repos registered in
   `registered-imports.json`, including non-GitHub sources (GitLab, Bitbucket, Codeberg, etc.)
3. **`upstream-commits.yml` / `upstream-prs.yml`** (daily) — detects direct commits
   and open PRs in OSP/OOC that haven't been reflected upstream, and opens PRs in I-D-1896

### Outbound (I-D-1896 → OSP → OOC → GitLab)

The mirror chain runs in sequence, each leg triggered by the previous:

```
mirror-to-osp.yml  ──►  mirror-osp-to-ooc.yml  ──►  GitLab CI (sync-to-gitlab.yml)
   (every 6h at :13)     (every 6h at :45)           (on OSP push)
```

`full-chain-flush.yml` orchestrates a complete end-to-end run of all three legs
plus README updates, sync, and validation in a single coordinated sequence.

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

Token expiry is monitored weekly by `token-health.yml`. See [Token Rotation](../AGENTS.md#token-rotation)
for rotation procedures.
