# Akamai + Linode monorepo architecture

Status: proposed architecture and implementation plan; no upstream repositories have been bulk-imported and no new repositories have been created.

## Goal

Create three repositories under the `Interested-Deving-1896` personal GitHub account:

1. `Akamai-Monorepo` — curated, source-preserving collection of approved projects from `akamai-developers`.
2. `Linode-Monorepo` — curated, source-preserving collection of approved projects from `linode`.
3. `Akamai-Linode-Monorepo` — unified integration layer consuming the two source monorepos while preserving their boundaries.

Register the unified repository with Fork-Sync-All only after its source manifests, sync policy, validation, and rollback behavior are tested.

## Important distinction: monorepo versus mirror

These should not be blind copies of entire organizations. Each upstream repository is an independently reviewed source unit. The monorepos aggregate approved source units, but must not erase their upstream identity, licence, history, branch/tag provenance, or update boundary.

Recommended layout:

```text
Akamai-Monorepo/
  projects/<upstream-repo>/
  manifests/repositories.json
  provenance/<upstream-repo>.json
  licenses/<upstream-repo>/
  reports/

Linode-Monorepo/
  projects/<upstream-repo>/
  manifests/repositories.json
  provenance/<upstream-repo>.json
  licenses/<upstream-repo>/
  reports/

Akamai-Linode-Monorepo/
  sources/akamai/       # pinned source-monorepo reference/subtree
  sources/linode/       # pinned source-monorepo reference/subtree
  integration/
  manifests/source-lock.json
  policies/
  reports/
```

The source monorepos should retain independent update cadence. The unified repository should consume pinned commits or release/tag references, not silently rewrite source history. If subtree snapshots are used, preserve the source repository URL, source commit, import timestamp, licence/NOTICE files, and a machine-readable mapping from each imported path to its upstream origin.

## Import policy

1. Generate canonical paginated inventories for both organizations, including archived/disabled metadata.
2. Classify projects by purpose, runtime, language, container/build artifacts, activity, licence, dependency posture, and architecture.
3. Exclude archived/disabled projects from default import candidates; retain them in reports.
4. Require a per-repository allowlist decision. Do not bulk-import every repository by default.
5. Preserve source files, Dockerfiles, Compose files, OCI metadata, licences, notices, and provenance. No destructive conversion.
6. Record exclusions and reasons so the result is reproducible and auditable.
7. Keep source updates read-only: sync only from upstream into the personal-account monorepos. Never push changes back to Akamai or Linode.

## Suggested manifest contract

Each source manifest entry should include:

- upstream owner/repository and canonical URL;
- upstream default branch, pinned commit, and optional tag/release;
- destination path;
- licence identifier and licence/NOTICE file locations;
- archived/disabled/fork flags and repository visibility;
- project category and runtime classification;
- discovered build/container files;
- import approval reference and review date;
- last successful sync commit and validation report;
- exclusions, unresolved risks, and operator notes.

Do not store credentials, private source payloads, or secret values in manifests.

## Synchronization model

- Discovery is read-only and paginated.
- Imports run only for manifest allowlisted repositories.
- Updates are staged as branches/PRs in the personal-account monorepos.
- Deletions, renames, licence changes, default-branch changes, force pushes, and large history rewrites must be surfaced for review rather than applied silently.
- Each sync is idempotent and records source commit, destination commit, file/path mapping, and validation outcome.
- Preserve per-source Git history where practical using a verified subtree/subdirectory import mechanism. If history preservation is not available, use a documented snapshot import with exact commit provenance; never claim it is history-preserving.
- No source-side writes, GitHub App installation changes, token scope changes, billing, or external infrastructure provisioning are part of this plan.

## Unified integration repository

The unified repository should not become a second unreviewed copy of all source content. It should provide:

- pinned references/lock manifest for the two source monorepos;
- shared compatibility and policy tooling;
- cross-provider adapters and examples;
- common CI and security/licence reporting;
- a unified project catalogue with links back to the original upstream repositories;
- an integration test matrix.

The two source monorepos remain the authoritative personal-account aggregation layers; the unified repo composes them and carries only the cross-provider integration logic plus explicitly pinned source snapshots/references.

## Fork-Sync-All integration

FSA should register `Interested-Deving-1896/Akamai-Linode-Monorepo` as a downstream input only after the repository exists and its manifests validate. Prefer the existing import registry and mirror lifecycle rather than inventing a parallel synchronizer.

Integration gates:

1. schema validation of source manifests and lockfile;
2. licence/provenance completeness;
3. deterministic inventory and pagination tests;
4. dry-run sync with no writes;
5. conflict/deletion/rename/force-push tests;
6. branch/PR-only update mode;
7. secret scanning and dependency/security checks;
8. full CI on exact PR head;
9. end-to-end test using a small, explicitly approved public candidate set;
10. operator approval before production scheduling or any external side effect.

## Docker-to-Incus relationship

The monorepos are source aggregation layers, not container images. FSA's Docker-to-Incus engine should inspect approved imported project directories and generate additive Incus definitions on FSA-controlled branches. Keep original Docker/Compose files. Require semantic validation for multi-stage builds, build args, architecture variants, health checks, networks, volumes, capabilities, devices, GPU, secrets, and entrypoints. Unsupported constructs must fail with a clear report; do not silently approximate them.

Do not run the current write-capable `scripts/docker-to-incus.sh` against upstream organization repositories. Its current `UPSTREAM_OWNER` setting controls both enumeration and write/delete destination, and the current conversion removes Docker source files. It must first be redesigned into a non-destructive, additive plan/convert/validate pipeline.

## Current evidence and blockers (2026-11-13)

- The earlier repository-search cross-check returned 57 `akamai-developers` and 118 `linode` public repository results, including 13 archived Linode results. These are search-index results, not a canonical organization inventory artifact.
- The canonical paginated Upstream Engine report still needs to be run through the manual workflow and its JSON artifact retained.
- `linode/apl-core` is a possible Incus development/toolbox pilot (Apache-2.0), but it has not been approved for import.
- `akamai-developers/akamai-workshop-solution-architect-agent` has a Dockerfile, but its root LICENSE was not found in the source-level check; hold pending licence/NOTICE and data-flow review.
- The connected GitHub account is the `Interested-Deving-1896` personal account. The connected organization-membership lookup returned no organizations.
- The currently exposed GitHub connector actions support repository search/listing and file/branch operations, but no repository-creation or Git-native full-history import action was available during this implementation pass. Therefore the three destination repositories have not been created and no full-history import is claimed.

## Completion criteria

This work is end-to-end only when all three repositories exist under the intended personal account; both source inventories and allowlists are complete; source updates are deterministic and provenance-preserving; the unified lockfile is reproducible; FSA integration passes exact-head CI; and at least one approved project completes the import → validation → additive Incus conversion → Incus smoke-test path. Any paid runner/cloud/registry use or production scheduling needs separate approval.

## Reusing Fork-Sync-All's existing Clone Org and Merge Monorepo workflows

The requested workflow composition is the preferred direction, but the current implementations are not yet safe to dispatch for this personal-account monorepo design without changes.

### Clone Org (.github/workflows/clone-org.yml / scripts/clone-org.sh)

- It enumerates and clones every repository returned by the source organization API, subject only to optional fork/archive/private/name filters. It has no per-repository manifest allowlist or licence/security approval gate.
- It creates one destination repository per upstream repository, not a single Akamai-Monorepo or Linode-Monorepo.
- Its create path uses the GitHub organization endpoint POST /orgs/{TARGET_ORG}/repos. The requested destination is the Interested-Deving-1896 personal account, so this path must support POST /user/repos (or otherwise explicitly distinguish account from organization targets).
- skip_archived defaults to false, skip_forks defaults to false, and ongoing_sync/mirror options can create additional writes and registrations. Those must remain disabled until allowlisting and target safety are implemented.
- The script pushes branches and tags to created/existing destinations. It is not a dry-run and does not currently build the curated per-source monorepo layout.

### Merge Repos into Monorepo (.github/workflows/merge-to-monorepo.yml / scripts/merge-to-monorepo.sh)

- This workflow already accepts explicit url/subdir pairs and can preserve source commit ancestry through its filter-repo/subdirectory merge approach. It is a suitable second-stage engine after curated source repos are available.
- The workflow hardcodes MONOREPO_OWNER: Interested-Deving-1896 and its auto-create path also uses POST /orgs/{MONOREPO_OWNER}/repos; this needs a personal-account-safe creation path or a verified existing target URL.
- The script previously used --force-with-lease and then fell back to unconditional --force. The fallback has now been removed; a rejected normal push fails closed.
- The sequential conflict fallback previously used the ours strategy. It has now been removed; a merge conflict aborts that source import and returns failure instead of recording a misleading merge.
- LFS fetch failures now fail the source preparation instead of being ignored.
- Source URLs and destination subdirectories receive basic safety validation; the workflow also requires an explicit confirm_import acknowledgement (default false) before any import attempt.
- These changes are a first hardening layer, not a complete manifest/allowlist implementation. N-parent mode, provenance/licence gates, source SHA pinning, personal-account auto-creation, and a non-writing preflight remain unresolved.

### Required orchestration

1. Use the read-only Upstream Engine inventory/export stage for Akamai and Linode.
2. Generate reviewed allowlist manifests with exact upstream repository, pinned source commit, destination subdirectory, licence/NOTICE status, and approval reference.
3. Do not use Clone Org as the monorepo construction stage: it creates one destination repository per source repository and has no per-repository manifest allowlist. It may be used later only for a separately approved mirror/clone use case after personal-account creation and allowlist safeguards are implemented.
4. Create or verify the two destination monorepos through an account-safe path, then import only allowlisted upstream URLs using the hardened Merge Monorepo workflow. Keep confirm_import false until each source URL/path pair and target are reviewed; do not enable mirror registration.
5. Run the unified merge with pinned source-monorepo commit SHAs and stable sources/akamai and sources/linode paths. The same fail-closed conflict and non-force push rules apply.
6. Validate provenance, licences, tree contents, commit ancestry, LFS objects, and reproducibility. Stage updates as PRs.
7. Register the unified monorepo with FSA only after the end-to-end tests pass.

No workflow was dispatched, no upstream repository was cloned/imported, no destination repository was created, and no mirror-chain propagation or ongoing-sync registration occurred. The manual Upstream Engine inventory remains the safe first execution step.
