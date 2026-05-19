<!-- AI:skip -->
# fork-sync-all

[![Built with Ona](https://ona.com/build-with-ona.svg)](https://app.ona.com/#https://github.com/OpenOS-Project-OSP/fork-sync-all)

Sync and mirror infrastructure for the three-org chain:

```
Interested-Deving-1896  ──►  OpenOS-Project-OSP  ──►  OpenOS-Project-Ecosystem-OOC
        ▲                                                         │
        └─────────── upstream-commits / upstream-prs ────────────┘
```

---

## Workflows

### Sync & Mirror

| Workflow | Schedule | What it does |
|---|---|---|
| `sync-forks.yml` | Hourly `:00` | Syncs all `Interested-Deving-1896` forks with their upstreams |
| `sync-pieroproietti-forks.yml` | Hourly `:05` | Fast-path sync for pieroproietti forks only |
| `mirror-to-osp.yml` | Hourly `:00` | Mirrors `Interested-Deving-1896` repos into `OpenOS-Project-OSP`; gated on clean CI and no open PRs in `Interested-Deving-1896` (bypassed for repos in `NO_GATE_REPOS` or when `FORCE=true`) |
| `mirror-osp-to-gitlab.yml` | Hourly `:30` | Mirrors `OpenOS-Project-OSP` repos into GitLab `openos-project`; auto-enables `allow_force_push` on protected branches before each push |
| `mirror-orgs-full.yml` | Manual / scheduled | Full mirror pass across all orgs; used for initial seeding or recovery |
| `mirror-orgs-watchdog.yml` | On `workflow_run` | Triggers a full mirror pass when the hourly mirror reports failures |
| `sync-from-gitlab.yml` | Daily `04:22` | Pulls GitLab `openos-project` repos back into `Interested-Deving-1896` (scheduled fallback; primary trigger is GitLab CI on push); access-denied clone failures are non-fatal |
| `sync-to-gitlab.yml` | Daily `03:17` | Pushes `Interested-Deving-1896` repos to their GitLab counterparts using the full namespace path from `config/gitlab-subgroups.yml` |
| `sync-registered-imports.yml` | Hourly `:50` | Re-syncs all repos registered in `registered-imports.json` |
| `sync-upstream-sources.yml` | Daily `01:30` / Manual | Syncs upstream origin repos referenced in `## Origins` sections; `patch-origins` job seeds missing Origins sections (manual dispatch only) |
| `sync-btrfs-devel-branches.yml` | Scheduled | Syncs btrfs development branches |

### Import

| Workflow | Trigger | What it does |
|---|---|---|
| `import-repo.yml` | Manual | Imports any git repo from any platform into `Interested-Deving-1896` |
| `fork-neon-repos.yml` | Manual (one-shot) | Forks the 6 KDE Invent neon repos (`ubuntu-core`, `pkg-kde-tools`, `pkg-kde-jenkins`, `pkg-kde-dev-scripts`, `docker-images`, `qt-kde-team.pages.debian.net`) into `Interested-Deving-1896` and pushes them through the OSP mirror chain |

**Import workflow inputs:**
- `repo_url` — source URL (GitHub, GitLab, Bitbucket, Codeberg, Sourcehut, Gitea, or any git host)
- `repo_name` — optional rename in `Interested-Deving-1896` (defaults to source name)
- `mirror_to_osp_ooc` — push through the OSP → OOC chain immediately
- `ongoing_sync` — register in `registered-imports.json` for hourly re-sync

### Dependency graph

| Workflow | Schedule | What it does |
|---|---|---|
| `generate-dep-graph.yml` | Manual / on push | Generates `dep-graph/origins.{md,json,dot}` from `## Origins` sections across all 36 OSP-bound repos |

The dep-graph tracks which `Interested-Deving-1896` repos are forks of upstream projects. Output files are committed directly to `main`. The 36 OSP-bound repos are defined in `scripts/generate-dep-graph.sh` (`OSP_REPOS` array).

### Maintenance

| Workflow | Schedule | What it does |
|---|---|---|
| `reconcile-org-refs.yml` | Manual / on push | Rewrites org names in file content across all three orgs; includes a label conversion pass for build/install/registry commands; `gitlab-only` mode updates GitLab project metadata without touching GitHub |
| `upstream-commits.yml` | Hourly `:45` | Detects direct commits to OSP/OOC not reachable in `Interested-Deving-1896` and opens PRs; skips SHAs already reachable on any branch; `upstream-commits/*` branches with no open PR are deleted by `cleanup-branches.yml` |
| `upstream-prs.yml` | Hourly `:23` | Syncs open PRs from OSP/OOC upstream into `Interested-Deving-1896` |
| `add-mirror-repo.yml` | Manual | Adds a new repo to the OSP + OOC mirror chain |
| `setup-osp-mirrors.yml` | Manual | Injects `mirror-osp-to-ooc.yaml` into all OSP repos |
| `resolve-failures.yml` | Daily `07:30` | AI-assisted CI failure resolver (GitHub Models); scoped to the 36 OSP-bound repos via `OSP_REPOS_OVERRIDE` |
| `notify-poller.yml` | Every 15 min | Polls GitHub notifications for unread CI failure alerts; triggers `resolve-failures.yml` immediately when any are found |
| `rate-limit-rerun.yml` | Every 30 min | Scans recently-failed runs, identifies those that failed due to rate limiting, and re-dispatches them after the reset window with `rate_limit_rerun=true` |
| `rate-limit-status.yml` | Manual | On-demand rate limit status check across GitHub REST API, GitLab API, and GitHub Models API |
| `token-health.yml` | Weekly (Mon 09:00) | Checks expiry and staleness of all GitHub Actions secrets |
| `validate-config.yml` | On push | Validates `config/gitlab-subgroups.yml` and other config files |
| `cleanup-branches.yml` | Scheduled / Manual | Deletes stale branches across `Interested-Deving-1896` repos |
| `rebase-lts.yml` | Weekly | Rebases the `lts` branch of `penguins-eggs` onto `master`; syncs `master` from upstream before rebasing; rebuilds `all-features` onto `master` in-place first |
| `sync-eggs-docs-to-book.yml` | On push | Syncs `penguins-eggs` docs into `penguins-eggs-book` |
| `mirror-artifacts.yml` | Scheduled | Mirrors release artifacts (packages, containers, flatpaks) |
| `mirror-releases.yml` | Hourly `:00` / Manual | Mirrors GitHub Releases and their assets from `Interested-Deving-1896` to OSP and OOC; supports `repo_filter`, `release_tag`, `dry_run`, and `force` inputs |
| `update-infra-deps.yml` | Scheduled | Updates infrastructure dependencies (action versions, etc.) |
| `pr-automation.yml` | On PR events | Auto-labels and routes pull requests |
| `rotate-token.yml` | Manual | Rotates `SYNC_TOKEN` and updates dependent secrets |
| `readme-wizard.yml` | Manual | Interactive README generation for a single repo |
| `translate-readmes.yml` | Manual | Translates README files using GitHub Models |
| `lts-readmes.yml` | Manual | Generates LTS-specific README sections |
| `inject-badges.yml` | Manual | Injects status badges into READMEs |
| `repo-manifest.yml` | Manual | Generates a manifest of all repos across all orgs |
| `clone-org.yml` | Manual | Clones an entire org locally for bulk operations |
| `merge-to-monorepo.yml` | Manual | Merges multiple repos into a monorepo structure |
| `sync-template.yml` | Manual / on push to template files | Syncs `fork-sync-all`'s file tree into registered consumer repos; supports four profiles (`full`, `mirror`, `infra-core`, `standalone`); push trigger reads `config/template-consumers.yml` and propagates to all enabled consumers with per-repo `force` and `skip_osp_setup` overrides |

### Workflow inputs

All workflows expose a `workflow_dispatch` trigger with typed inputs. Common inputs across most workflows:

| Input | Type | Effect |
|---|---|---|
| `dry_run` | boolean | Print actions without making changes |
| `repo_filter` | string | Restrict processing to a single repo name |
| `force` | boolean | Bypass safety gates (CI gate, duplicate checks, etc.) |
| `rate_limit_rerun` | boolean | Set by `rate-limit-rerun.yml`; prevents re-trigger loops (see [Rate limits](#rate-limits)) |

### OSP-priority scoping

Workflows that scan all repos (`resolve-failures.yml`, `update-readmes.yml`, `lts-readmes.yml`, `reconcile-org-refs.yml`) use `workflow_run` triggers chained off OSP-bound workflows so they process OSP-mirrored repos first. The 36 OSP-bound repos are defined in `scripts/generate-dep-graph.sh` (`OSP_REPOS` array) and can be overridden at dispatch time via `OSP_REPOS_OVERRIDE`.

### CI gate (`mirror-to-osp.yml`)

Before mirroring a repo to OSP, `scripts/mirror-to-osp.sh` checks that:
1. All CI checks on the `Interested-Deving-1896` default branch are passing
2. There are no open PRs in `Interested-Deving-1896` for that repo

Repos that require private CI infrastructure (e.g. container builds) are listed in `NO_GATE_REPOS` and bypass the check. The gate can be bypassed globally with `FORCE=true` at dispatch time.

---

## Secrets

| Secret | Used by | Notes |
|---|---|---|
| `SYNC_TOKEN` | All workflows | GitHub PAT — `repo` + `workflow` + `admin:org` scopes |
| `GH_SYNC_TOKEN` | GitLab CI `sync-from-gitlab` job | Same PAT stored as a GitLab CI variable |
| `GITLAB_SYNC_TOKEN` | `mirror-osp-to-gitlab.yml`, `sync-from-gitlab.yml`, `sync-to-gitlab.yml` | GitLab PAT — `api` + `write_repository` on `openos-project` group. The `api` scope is required for `allow_force_push` protection rule management used by `sync-to-gitlab.yml`. |
| `BITBUCKET_TOKEN` | `import-repo.yml`, `sync-registered-imports.yml` | Bitbucket app password (private repos only) |
| `GITEA_TOKEN` | `import-repo.yml`, `sync-registered-imports.yml` | Gitea/Codeberg PAT (private repos only) |
| `ADD_MIRROR_REPO_SYNC` | `add-mirror-repo.yml` | Scoped PAT for repo creation |

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

### KDE Invent neon repos

Six KDE Invent repos used by `kde-neon-editions` are seeded via `fork-neon-repos.yml` and tracked here for ongoing sync:

| Source (invent.kde.org) | Target repo |
|---|---|
| `neon/neon-images` | `neon-images` |
| `neon/neon-packaging` | `neon-packaging` |
| `neon/neon-settings` | `neon-settings` |
| `neon/neon-desktop` | `neon-desktop` |
| `neon/neon-plasma` | `neon-plasma` |
| `neon/neon-frameworks` | `neon-frameworks` |

These use `platform: gitlab` (KDE Invent is a GitLab instance). `GITEA_TOKEN` is not required for public KDE Invent repos; the clone URL is unauthenticated HTTPS.

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

### Automated re-trigger

`rate-limit-rerun.yml` runs every 30 minutes and automatically re-triggers workflows that failed due to rate limits, so no manual intervention is needed for transient exhaustion.

**How it works:**

1. `scripts/scan-rate-limit-failures.sh` queries the GitHub Actions API for runs that failed in the last 2 hours and searches their logs for the string `rate limit exceeded` (case-insensitive).
2. For each matching run, `scripts/rerun-after-rate-limit.sh` dispatches a fresh `workflow_dispatch` event against the same workflow, passing `rate_limit_rerun=true` as an input.
3. `scripts/rl-manifest-to-md.py` formats the results into a job summary table.

**Loop guard:** Re-triggered runs are dispatched via `workflow_dispatch` (not the `rerun-failed-jobs` API) with `rate_limit_rerun=true` injected into `inputs`. Every workflow run prints its `INPUTS_JSON` via `write-summary.sh`. The scanner reads this field from the run's log before deciding to re-trigger — if `"rate_limit_rerun": "true"` is present, the run is skipped. This prevents a re-triggered run that itself hits a rate limit from being re-triggered again indefinitely.

**On-demand status check:** `rate-limit-status.yml` (manual dispatch) runs `scripts/check-rate-limits.sh` and prints current remaining quotas for the GitHub REST API, GitHub Models API, and GitLab API to the job summary.

### Diagnosing a rate-limit failure

1. Open the failed run log and search for `[rate-limit]` or `rate limit exceeded`.
2. The log line includes the HTTP status, sleep duration, and attempt number.
3. If all 3 retries were exhausted, `rate-limit-rerun.yml` will pick it up within 30 minutes and re-trigger it automatically.
4. If failures persist across multiple re-trigger cycles, check that `SYNC_TOKEN` is valid (`gh auth status`) and has the required scopes (`repo`, `workflow`, `admin:org`).
5. To check current quota headroom immediately, run `rate-limit-status.yml` via workflow dispatch.

## GitLab sync

Three workflows handle the GitHub ↔ GitLab bridge:

| Workflow | Direction | Notes |
|---|---|---|
| `mirror-osp-to-gitlab.yml` | GitHub OSP org → GitLab `openos-project` | Mirrors all OSP repos; uses `allow_force_push` on protected branches |
| `sync-from-gitlab.yml` | GitLab `openos-project` → GitHub | Pulls changes back; access-denied clone failures are skipped (non-fatal) |
| `sync-to-gitlab.yml` | GitHub → GitLab subgroups | Uses `path:` field from `config/gitlab-subgroups.yml` to resolve the target subgroup path |

### `config/gitlab-subgroups.yml`

Each entry maps a GitHub org/repo pattern to a GitLab subgroup. The `path:` field is the GitLab subgroup path (not the display name):

```yaml
- match: "Interested-Deving-1896/*"
  path: "openos-project/mirrors/interested-deving"
```

`sync-to-gitlab.yml` reads `path:` via the Python parser in `scripts/sync-to-gitlab.sh`. Earlier versions ignored `path:` and used the display `name:` field, which caused pushes to land in the wrong subgroup — this is now fixed.

### Required secrets and CI variables

- `GITLAB_SYNC_TOKEN` — GitLab PAT with `api` + `write_repository` scopes (see [Secrets](#secrets))
- `GH_SYNC_TOKEN` — GitHub PAT stored as a GitLab CI/CD variable in `openos-project/ops/fork-sync-all`; used by the GitLab CI `sync-from-gitlab` job to authenticate pushes back to GitHub

Per-repo push triggers (so a commit to e.g. `penguins-eggs` on GitLab fires the sync immediately) can be wired up via `scripts/provision-maintenance.sh` once the tokens are in place.

---

## Mirror chain timing

```
:00  mirror-to-osp.yml        Interested-Deving-1896 → OSP
:05  sync-pieroproietti        pieroproietti forks fast-path
:15  mirror-osp-to-ooc.yaml   OSP → OOC  (per-repo, injected by setup-osp-mirrors)
:23  upstream-prs.yml          OOC/OSP PRs → Interested-Deving-1896
:30  mirror-osp-to-gitlab.yml  OSP → GitLab openos-project
:45  upstream-commits.yml      Direct OSP/OOC commits → PRs in Interested-Deving-1896
:50  sync-registered-imports   External platform imports re-sync
```
