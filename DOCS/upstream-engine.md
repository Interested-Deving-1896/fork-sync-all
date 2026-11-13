# Upstream Engine

## Purpose

The Upstream Engine audits archived, stale, abandoned, or otherwise lagging
projects and determines whether their source code, dependencies, build system,
and release metadata can be safely brought forward to current upstream
counterparts.

It is distinct from ordinary fork synchronization:

- **Fork sync** transfers upstream commits while preserving the fork's branch
  relationship.
- **Upstream Engine** performs an evidence-based lifecycle and modernization
  assessment. It can identify a successor project, map dependencies, prepare
  migration changes, and validate the result even when a direct merge is
  impossible.

The engine is provider-neutral. GitHub is one supported source, not an
architectural requirement. Adapters should support GitLab, Codeberg, and
other Git-compatible or source-archive providers where their APIs permit.

## Core lifecycle

1. **Discover** — use either an explicit repository allowlist or an explicitly
   named organization in read-only discovery mode. Organization discovery is
   opt-in, public-only, paginated, and metadata-only; it does not imply import
   approval. Never expand into an account or organization implicitly.
2. **Classify** — collect archive status, last activity, releases, tags, default
   branch, security advisories, license, maintainers, and successor notices.
   Distinguish archived from merely quiet. Metadata keyword categories are
   triage hints, not suitability or security verdicts.
3. **Resolve lineage** — identify canonical upstreams, renamed repositories,
   successor projects, replacement libraries, and split/merged projects.
   Record evidence and confidence; never infer identity from a similar name
   alone.
4. **Inventory source and dependencies** — inspect manifests, lockfiles,
   submodules, vendored code, build scripts, CI, toolchains, generated files,
   and runtime dependencies. Record direct and transitive dependency edges.
5. **Plan compatibility** — compare current project state with upstream
   releases and supported version ranges. Identify API/ABI changes, schema
   migrations, platform support changes, and license obligations.
6. **Prepare changes** — prefer a minimal, reviewable migration branch or PR.
   Preserve local patches and human-owned files. Do not overwrite local work
   simply to make a fork byte-identical to upstream.
7. **Validate** — run project tests, static analysis, build/package checks,
   dependency/security scans, provenance checks, and supported-platform CI.
   Compare artifacts and behavior where feasible.
8. **Report and maintain** — publish an audit report with source evidence,
   dependency graph, recommended action, unresolved risks, and next review
   date. Re-audit on release events or a configurable schedule.

## Outcomes

Each project receives one explicit disposition:

- `sync` — direct upstream synchronization is safe and appropriate;
- `forward-port` — preserve local changes while porting to a newer upstream;
- `migrate-successor` — move to a verified successor or replacement;
- `maintain-compat` — retain the current code with documented compatibility
  patches because no safe upgrade exists;
- `archive-readonly` — retain as historical source and stop automated writes;
- `needs-human-review` — lineage, licensing, security, or migration risk is
  unresolved.

An archived source repository is never unarchived or rewritten automatically.
A new maintained fork or successor branch may be proposed separately.

## Required safeguards

- Default to report-only. A successful audit is not permission to write.
- Require explicit repository registration before migration or synchronization.
  Organization discovery may produce candidates but never registers them.
- Never delete branches, tags, releases, source history, or local-only files.
- Never force-push, rewrite protected branches, or merge its own PRs.
- Do not silently change licenses or remove copyright notices.
- Do not update dependencies across incompatible major versions without
  migration analysis and tests.
- Treat build scripts, package hooks, CI workflows, and dependency metadata as
  executable/untrusted input. Run them in isolated, ephemeral environments
  with no production secrets and restricted network access.
- Generate an SBOM and retain checksums/provenance for downloaded sources and
  build artifacts where supported.
- Preserve reproducible build inputs and pin versions/digests for validation.
- Use least-privilege, short-lived credentials; never expose tokens to
  untrusted build steps.
- Require human approval for successor adoption, license changes, destructive
  migrations, release publication, and any production deployment.

## Dependency policy

Build a graph that distinguishes:

- runtime dependencies;
- build and test dependencies;
- optional integrations;
- vendored or copied source;
- submodules and Git-based dependencies;
- toolchains and platform SDKs;
- generated artifacts and external services.

For each edge, record declared version/range, resolved version, source,
license, maintenance status, known vulnerabilities, and whether it is
reproducibly pinned. Prefer supported upstream releases, but do not blindly
upgrade a transitive dependency if the parent project has not declared
compatibility.

## Release selection

"Current" means the latest non-prerelease release that is supported by the
project's own compatibility policy, unless the project explicitly opts into
pre-releases or tracks a development branch. Record the release/tag and commit
SHA used for every audit. Avoid floating `latest` references in production
build inputs.

## Suggested report

Every run should produce machine-readable JSON and a human-readable Markdown
report containing:

- project identity and archived/stale state;
- canonical upstream and successor candidates with evidence;
- source snapshot and license;
- direct/transitive dependency inventory and SBOM reference;
- outdated components and security findings;
- compatibility/migration assessment;
- proposed changes and validation results;
- decision, confidence, blockers, and human approvals;
- run timestamp and next review date.

## Rollout

1. Read-only organization/repository metadata inventory and lineage reports.
2. Dependency/SBOM and release comparison, with no source writes.
3. Draft migration branches and PRs for low-risk projects.
4. CI validation and human review gates.
5. Optional scheduled operation, still report-only unless a project has a
   separately approved automation policy.

The engine must not reuse the registered-imports mirror mechanism as a
substitute for source migration. It should integrate with existing fork sync,
dependency-risk audit, and PR review systems while keeping their permissions
and responsibilities separate.

## Initial organization discovery targets

The initial manual discovery targets for the Akamai/Linode integration audit are:

- `akamai-developers` — Akamai developer ecosystem;
- `linode` — Akamai Connected Cloud/Linode SDK, CLI, infrastructure-as-code,
  Kubernetes and platform tooling.

These organizations are inventory sources only. No repository is imported,
forked, mirrored, or written to by discovery. Candidate selection remains a
separate reviewed step.
