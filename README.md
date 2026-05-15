# fork-sync-all

[![Built with Ona](https://ona.com/build-with-ona.svg)](https://app.ona.com/#https://github.com/Interested-Deving-1896/fork-sync-all)

<!-- AI:start:what-it-does -->
<!-- AI:end:what-it-does -->

---

<!-- AI:start:architecture -->
<!-- AI:end:architecture -->

---

<!-- AI:start:ci -->
<!-- AI:end:ci -->

---

<!-- AI:start:mirror-chain -->
<!-- AI:end:mirror-chain -->

---

## Usage

<!-- LTS:start:usage -->

Every workflow in this repo can be triggered manually from the GitHub Actions
UI at **Actions → [workflow name] → Run workflow**. All workflows also run on
their configured schedule without any manual intervention.

### Running a workflow manually

1. Go to [Actions](https://github.com/Interested-Deving-1896/fork-sync-all/actions)
2. Select the workflow from the left sidebar
3. Click **Run workflow** (top right of the run list)
4. Fill in the inputs and click **Run workflow**

---

### Common inputs (present on most workflows)

| Input | Type | Default | What it does |
|---|---|---|---|
| `repo_filter` | string | _(blank = all)_ | Substring match on repo name — limits the run to repos whose name contains this string. E.g. `penguins` processes only `penguins-*` repos. |
| `dry_run` | boolean | `false` | Prints every action the workflow would take without making any changes. Safe to run at any time. |
| `force` | boolean | `false` | Re-processes repos even if they appear up to date. Useful after a manual fix or to verify idempotency. |

---

### Workflow-specific inputs

#### Sync & import workflows

| Workflow | Extra inputs | Notes |
|---|---|---|
| `sync-forks.yml` | `branch_filter` (string) | Limit sync to branches whose name contains this string |
| `sync-pieroproietti-forks.yml` | `upstream_user` (string) | Override the upstream GitHub user to sync from (default: `pieroproietti`) |
| `sync-registered-imports.yml` | `source_filter` (choice: `all` / `github` / `gitlab` / `bitbucket` / `gitea`) | Limit re-sync to imports from a specific platform |
| `sync-from-gitlab.yml` | `subgroup_filter` (choice) | Limit to a specific GitLab subgroup under `openos-project` |
| `import-repo.yml` | `repo_url`, `repo_name`, `mirror_to_osp_ooc`, `ongoing_sync` | One-shot import from any git host; `ongoing_sync` registers the repo for hourly re-sync |
| `clone-org.yml` | `source_platform`, `source_org`, `include_filter`, `exclude_filter`, `ongoing_sync`, `mirror_to_osp`, `concurrency`, `clone_depth` | Bulk-clone an entire org or user from GitHub / GitLab / Bitbucket / Gitea |

#### Mirror workflows

| Workflow | Extra inputs | Notes |
|---|---|---|
| `mirror-to-osp.yml` | `force` | Force-push even if destination is ahead |
| `mirror-osp-to-gitlab.yml` | `subgroup_filter` (choice), `dry_run` | Limit to one GitLab subgroup |
| `mirror-releases.yml` | `release_tag` (string) | Mirror a specific release tag only |
| `mirror-orgs.yml` | `target_orgs` (choice: `both` / `osp-only` / `ooc-only`) | Push to one or both mirror orgs |
| `mirror-artifacts.yml` | `upstream_repo`, `release_tag` | Mirror artifacts for a specific repo/tag |
| `sync-btrfs-devel-branches.yml` | `branches` (string), `source_repo`, `target_repo` | Space-separated branch list; defaults to all branches in `kdave/btrfs-devel` |

#### Maintenance workflows

| Workflow | Extra inputs | Notes |
|---|---|---|
| `reconcile-org-refs.yml` | `orgs` (choice: `all` / `osp-only` / `ooc-only` / `gitlab-only`) | Limit rewrite pass to one org tier |
| `resolve-failures.yml` | `scan_owners` (string) | Space-separated orgs to scan; defaults to all three |
| `upstream-commits.yml` | `mirror_orgs` (string) | Override which mirror orgs to scan for direct commits |
| `upstream-prs.yml` | `mirror_orgs` (string) | Override which mirror orgs to scan for open PRs |
| `rebase-lts.yml` | `base_branch`, `feature_branch`, `lts_branch` | All default to the `penguins-eggs` convention; override for other repos |
| `rotate-token.yml` | `secret_name` (choice), `token_value`, `validate` | Updates a named secret and optionally validates it against its platform API |
| `update-infra-deps.yml` | `eol_window` (string, days), `scan_owners` | Flag actions/runners/runtimes within N days of EOL |

#### README workflows

| Workflow | Schedule | Extra inputs | Notes |
|---|---|---|---|
| `create-readmes.yml` | Daily 05:15 UTC | `repo_filter`, `dry_run` | Creates a README for any repo that has none |
| `update-readmes.yml` | Daily 05:00 UTC | `repos`, `dry_run`, `force_rewrite` | Regenerates AI-owned `<!-- AI:start:* -->` sections; `force_rewrite` strips `<!-- AI:skip -->` to migrate static READMEs |
| `translate-readmes.yml` | Daily 06:00 UTC | `source_lang`, `target_lang`, `scope`, `repos`, `force`, `normalize_to_english` | Translates READMEs; scheduled run always auto-detects and normalises non-English READMEs to English |
| `lts-readmes.yml` | Monthly | `repos`, `force`, `dry_run` | Standardises human-owned `<!-- LTS:start:* -->` sections against current repo state |
| `readme-wizard.yml` | Manual only | `repo`, `audience`, `tone`, `emphasis`, `sections`, `mode`, `preserve_human` | AI-guided README authoring with full control over structure and tone |

---

### Dry-run workflow

The recommended sequence when running any workflow for the first time or after
a long gap:

```
1. Run with dry_run=true            → review the log output
2. Run with dry_run=false, repo_filter=<one repo>  → verify on a single repo
3. Run with dry_run=false           → full run
```

---

### Scheduled run timing

All schedules are UTC. The hourly chain runs in this order each hour:

```
:00  mirror-to-osp          Interested-Deving-1896 → OSP
:05  sync-pieroproietti      pieroproietti forks fast-path
:15  mirror-osp-to-ooc       OSP → OOC (per-repo, injected by setup-osp-mirrors)
:23  upstream-prs            OSP/OOC PRs → Interested-Deving-1896
:30  mirror-osp-to-gitlab    OSP → GitLab openos-project
:30  reconcile-org-refs      Rewrite org references in OSP + OOC + GitLab
:45  upstream-commits        Direct OSP/OOC commits → PRs in Interested-Deving-1896
:45  setup-osp-mirrors       Ensure OSP mirror workflows are configured
:50  sync-registered-imports External platform imports re-sync
```

Daily jobs run at:

```
01:30  sync-upstream-sources   Sync external fork origins to upstream HEAD
05:00  update-readmes          Regenerate AI-owned README sections
05:15  create-readmes          Create READMEs for repos that have none
06:00  translate-readmes       Normalize non-English READMEs to English
07:30  resolve-failures        AI-assisted CI failure scan and fix
```

<!-- LTS:end:usage -->

---

## Secrets

| Secret | Used by | Notes |
|---|---|---|
| `SYNC_TOKEN` | All workflows | GitHub PAT — `repo` + `workflow` + `admin:org` scopes |
| `GH_SYNC_TOKEN` | GitLab CI `sync-from-gitlab` job | Same PAT stored as a GitLab CI variable |
| `GITLAB_SYNC_TOKEN` | `mirror-osp-to-gitlab.yml`, `sync-from-gitlab.yml`, `sync-to-gitlab.yml` | GitLab PAT — `api` + `write_repository` on `openos-project` group |
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

## Contributors

<!-- LTS:start:contributors -->

| Contributor | Role | Notes |
|---|---|---|
| [Interested-Deving-1896](https://github.com/Interested-Deving-1896) | Owner, architect | Designed the three-org chain, all infrastructure decisions, token management |
| [Ona](https://app.ona.com) | AI pair programmer | Authored all workflows, scripts, and documentation across all sessions in this workspace |
| [Sébastien Vienneau](https://github.com/SebastienVienneau) | Contributor | Upstream commits mirrored via OSP |
| [OSPF1896](https://gitlab.com/ospf1896) | GitLab contributor | Commits originating from the GitLab mirror side |
| [openos-ci](https://gitlab.com/openos-project) | Automation bot | CI-generated commits from the OpenOS-Project GitLab group |

All contributors to mirrored repos are attributed in their respective upstream repositories. OSP and OOC mirrors link back to `Interested-Deving-1896` as the canonical source.

<!-- LTS:end:contributors -->

---

## Origins

<!-- AI:start:origins -->
<!-- AI:end:origins -->

---

## Resources

<!-- AI:start:resources -->
<!-- AI:end:resources -->

---

## License

<!-- LTS:start:license -->

[MIT](LICENSE) © 2026 [Interested-Deving-1896](https://github.com/Interested-Deving-1896)

<!-- LTS:end:license -->

---

## GitLab sync

The `mirror-osp-to-gitlab.yml`, `sync-from-gitlab.yml`, and `sync-to-gitlab.yml` workflows require `GITLAB_SYNC_TOKEN` to be set. The GitLab CI `sync-from-gitlab` job additionally requires `GH_SYNC_TOKEN` to be set as a CI/CD variable in `openos-project/ops/fork-sync-all` on GitLab.

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
