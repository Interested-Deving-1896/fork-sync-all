# fork-sync-all

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
| `mirror-to-osp.yml` | Hourly `:00` | Mirrors `Interested-Deving-1896` repos into `OpenOS-Project-OSP` |
| `mirror-osp-to-gitlab.yml` | Hourly `:30` | Mirrors `OpenOS-Project-OSP` repos into GitLab `openos-project` |
| `sync-from-gitlab.yml` | Daily `04:22` | Pulls GitLab `openos-project` repos back into `Interested-Deving-1896` (scheduled fallback; primary trigger is GitLab CI on push) |
| `sync-registered-imports.yml` | Hourly `:50` | Re-syncs all repos registered via the import workflow |

### Import

| Workflow | Trigger | What it does |
|---|---|---|
| `import-repo.yml` | Manual | Imports any git repo from any platform into `Interested-Deving-1896` |

**Import workflow inputs:**
- `repo_url` — source URL (GitHub, GitLab, Bitbucket, Codeberg, Sourcehut, Gitea, or any git host)
- `repo_name` — optional rename in `Interested-Deving-1896` (defaults to source name)
- `mirror_to_osp_ooc` — push through the OSP → OOC chain immediately
- `ongoing_sync` — register in `registered-imports.json` for hourly re-sync

### Maintenance

| Workflow | Schedule | What it does |
|---|---|---|
| `reconcile-org-refs.yml` | Manual / on push | Rewrites org names in file content across all three orgs; includes a label conversion pass for build/install/registry commands |
| `upstream-commits.yml` | Hourly `:45` | Detects direct commits to OSP/OOC and opens PRs in `Interested-Deving-1896` |
| `upstream-prs.yml` | Hourly `:23` | Syncs open PRs from OSP/OOC upstream into `Interested-Deving-1896` |
| `add-mirror-repo.yml` | Manual | Adds a new repo to the OSP + OOC mirror chain |
| `setup-osp-mirrors.yml` | Manual | Injects `mirror-osp-to-ooc.yaml` into all OSP repos |
| `resolve-failures.yml` | Daily `07:30` | AI-assisted CI failure resolver (GitHub Models) |
| `rebase-lts.yml` | Weekly | Rebases the `lts` branch of `penguins-eggs` |
| `sync-eggs-docs-to-book.yml` | On push | Syncs `penguins-eggs` docs into `penguins-eggs-book` |
| `mirror-artifacts.yml` | Scheduled | Mirrors release artifacts (packages, containers, flatpaks) |

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

## GitLab sync (pending)

The `mirror-osp-to-gitlab.yml` and `sync-from-gitlab.yml` workflows require `GITLAB_SYNC_TOKEN` to be set. The GitLab CI `sync-from-gitlab` job additionally requires `GH_SYNC_TOKEN` to be set as a CI/CD variable in `openos-project/ops/fork-sync-all` on GitLab.

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
