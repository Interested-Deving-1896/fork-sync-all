# OTA Update System

The OTA (over-the-air) system delivers workflow and script updates from
`fork-sync-all` to forks that have opted in. It is the mechanism by which
downstream forks stay current without manual merges.

---

## Concepts

**Upstream** — `Interested-Deving-1896/fork-sync-all`. The source of truth for
all OTA payloads.

**Fork** — any GitHub repo that has forked `fork-sync-all` and opted in to OTA.

**Payload** — a diff of files that changed between the fork's `pinned_sha` and
the latest upstream release tag. Only files the fork hasn't locally modified are
included.

**Registry** — `config/ota-registry.yml`. The list of all opted-in repos.

**Blocklist** — `config/ota-blocklist.yml`. Orgs and namespaces excluded from
OTA by default (the three mirror-chain orgs and the GitLab namespace).

---

## Lifecycle

```
Fork owner runs ota-opt-in
        │
        ▼
.ota/config.yml created in fork
Registration PR opened against fork-sync-all
        │
        ▼
PR merged → repo added to config/ota-registry.yml
        │
        ▼
ota-discover.yml (daily) also finds new opt-ins automatically
        │
        ▼
Semver tag pushed to fork-sync-all (v*.*.*)
        │
        ▼
ota-release.yml assembles payload per opted-in repo
Opens PR in each fork with the diff
        │
        ▼
Fork owner merges PR
ota-self-update.yml (runs in fork on schedule) updates pinned_sha
```

---

## Workflows

### `ota-opt-in.yml` — fork owner runs this once

Propagated to forks via the `standalone` template profile. The fork owner
triggers it via `workflow_dispatch`. It:

1. Creates `.ota/config.yml` in the fork with sensible defaults
2. Opens a registration PR against `fork-sync-all/config/ota-registry.yml`

**Inputs:**

| Input | Description | Default |
|---|---|---|
| `upstream_override` | Override the upstream source (for fork-of-fork cases) | _(auto-detected)_ |
| `mirror_chain_opt_in` | Set true if the fork is in the mirror chain | `false` |

---

### `ota-discover.yml` — runs daily in fork-sync-all

Scans GitHub for forks of `fork-sync-all` that contain `.ota/config.yml` with
`enabled: true`. For any not already in `config/ota-registry.yml`, opens a PR
to add them.

This is the passive discovery path — fork owners don't need to run `ota-opt-in`
if they create `.ota/config.yml` manually.

**Inputs:**

| Input | Description | Default |
|---|---|---|
| `dry_run` | Report new opt-ins without updating registry or opening PR | `false` |

---

### `ota-release.yml` — triggered on semver tag push

Triggered when a tag matching `v*.*.*` is pushed to `fork-sync-all`. It:

1. Iterates all repos in `config/ota-registry.yml` (skipping `disabled: true`)
2. For each repo, calls `ota-payload-build.sh` to assemble the diff
3. Opens a PR in the fork with the payload
4. Updates `CHANGELOG.md` in `fork-sync-all`

Repos in the blocklist orgs are skipped unless `mirror_chain_opt_in: true` is
set in their `.ota/config.yml`.

---

### `ota-self-update.yml` — runs in the fork on a schedule

Propagated to forks via the `standalone` template profile. Runs on a schedule
in the fork. It:

1. Checks the latest OTA release tag from `fork-sync-all`
2. Compares against the fork's `pinned_sha` in `.ota/config.yml`
3. If behind, applies the payload and updates `pinned_sha` and `pinned_at`

This is the self-healing path — if a fork owner doesn't merge the OTA PR,
`ota-self-update` will eventually apply the update automatically.

---

## Payload assembly

`scripts/ota-payload-build.sh` assembles the payload for a single fork:

1. Detects the fork's upstream parent via GitHub API (or uses `upstream_override`)
2. Diffs the fork's current state at `pinned_sha` against the latest upstream tag
3. Filters out:
   - Files listed in the fork's `exclude_paths`
   - Files the fork has locally modified (detected by comparing against upstream)
   - Files owned by template profiles (from `config/template-manifest.yml`)
     unless explicitly claimed via `workflow_overrides.claim`
4. Applies `workflow_overrides.disclaim` to remove any files the fork wants to
   manage independently

The result is a minimal set of files that are safe to overwrite in the fork.

---

## `.ota/config.yml` reference

Created in the fork by `ota-opt-in.yml`. All fields except `enabled` and `repo`
are optional.

```yaml
enabled: true                  # master switch
repo: "owner/repo-name"        # must match actual GitHub repo
host: "github"                 # "github" only currently
upstream_override: ""          # override upstream detection (fork-of-fork)
pinned_sha: ""                 # managed by ota-self-update — do not edit
pinned_at: ""                  # managed by ota-self-update — do not edit
ota_version: ""                # managed by ota-self-update — do not edit
mirror_chain_opt_in: false     # set true only for mirror-chain repos
workflow_overrides:
  claim: []                    # workflows OTA should manage even if in manifest
  disclaim: []                 # workflows OTA should NOT touch
exclude_paths: []              # glob patterns OTA never writes
include_paths: []              # re-include after exclude_paths
```

Full field documentation: `.ota/schema.yml` in this repo.

---

## Blocklist

`config/ota-blocklist.yml` defines two guards applied before any delivery:

**Guard 1 — org/namespace blocklist:**
The three mirror-chain GitHub orgs (`Interested-Deving-1896`,
`OpenOS-Project-OSP`, `OpenOS-Project-Ecosystem-OOC`) and the GitLab namespace
(`openos-project`) are excluded by default. A repo in these orgs can still
receive OTA by setting `mirror_chain_opt_in: true`.

**Guard 2 — profile filter:**
Only repos using the `standalone` template profile are eligible for OTA.
Repos on `core`, `extended`, or other profiles are managed by `sync-template.yml`
instead.

---

## Adding a fork to the registry manually

If `ota-opt-in` is unavailable or the fork owner prefers manual registration:

1. Create `.ota/config.yml` in the fork (copy from `.ota/schema.yml`, set `enabled: true` and `repo`)
2. Add an entry to `config/ota-registry.yml`:

```yaml
opted_in:
  - repo: owner/fork-name
    host: github
    registered_at: "2026-06-07"
    pinned_sha: ""
    discovery: false
    mirror_chain_opt_in: false
    disabled: false
```

3. Open a PR against `fork-sync-all` — `validate-config.yml` will check the entry.

---

## Disabling OTA for a repo

Set `disabled: true` in the registry entry. The repo stays registered but
receives no further deliveries until re-enabled. Alternatively, set
`enabled: false` in the fork's `.ota/config.yml` — `ota-discover` will
stop treating it as opted-in.

To remove permanently: delete the entry from `config/ota-registry.yml`.
