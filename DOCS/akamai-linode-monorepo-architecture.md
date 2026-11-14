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
