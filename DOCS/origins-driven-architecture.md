# Origins-driven architecture for Fork-Sync-All

## Purpose

FSA's Origins data should become the provenance and capability foundation used
by its engines, rather than documentation consulted only by README and
dependency-graph generators. The goal is an origins-aware, provider-neutral
control plane that can explain where a capability came from, what local
artifact implements it, which interfaces are supported, and what evidence
is required before that capability can be used.

This is an architectural contract and rollout plan. It does not claim that all
existing engines already consume a shared Origins API.

## Implemented foundation

The first executable slice is now part of this proposal branch:

- `scripts/origins.py` provides a shared, read-only YAML parser and normalized
  provenance model.
- `scripts/validate-origins.py` validates the manifest and can emit normalized
  JSON with `--json` for downstream consumers.
- Duplicate YAML keys, duplicate source identities, malformed records,
  unsupported relationship values, and mismatched source/URL paths are
  rejected rather than silently accepted.
- `scripts/generate-dep-graph.sh` uses the shared validator and stops when
  structured provenance is invalid.
- Validate Config runs the manifest validator and parser unit tests.

This is not yet a universal engine API. Existing consumers must be migrated
incrementally, with behavior-preserving tests, before the shared model can be
considered the common Origins interface across FSA.

## Sources of truth

FSA currently has several related but distinct origin sources. They should be
unified through a read-only normalized model, without conflating their meanings:

- dep-graph/provenance.yml: upstream projects whose logic, schemas, patterns,
  or concepts influenced FSA, including local artifacts that embody them.
- Each managed repository's ## Origins README section: human-readable
  repository-level provenance and upstream/fork relationships.
- dep-graph/origins.md and DOCS/generated/origins.md: generated dependency
  graph/report outputs; these are projections, not authoritative inputs.
- registered-imports.json and other provider registries: operational
  declarations for synchronization or provider participation. They remain
  distinct from attribution-only references.

The normalized model should retain source URL, forge/provider, relationship,
capability, affected artifact, version or revision when known, license,
maintenance status, trust classification, and whether the source is
operationally enabled. Missing or unknown fields must remain unknown.

## Shared Origins service

Introduce a deterministic Origins library and CLI as the only supported
parser/normalizer for these inputs. It should provide read-only operations to:

1. parse and validate the structured provenance manifest;
2. extract repository Origins sections using a Markdown-aware parser or a
   constrained, tested format;
3. resolve local artifacts to declared origin records;
4. expose a stable JSON representation for shell, Python, workflow, and API
   consumers;
5. report missing, stale, duplicate, ambiguous, and unreferenced records.

Existing generators and sync tools should migrate to this shared library in
small batches. Do not broadly rewrite every engine in one change. Operational
sync actions must retain explicit allowlists and dry-run/fail-closed safeguards;
provenance alone must never authorize a fork, network call, write, deployment,
or remote execution.

## Initial machine-readable engine contracts

The first incremental inventory is now represented by
`config/engine-inventory.yml`, with the contract shape defined in
`config/engine-manifest.schema.json`. Eight verified implementation boundaries are now registered incrementally:

- `origins-core`: read-only parser/normalizer and provenance validator.
- `nativelink-adapter`: optional REAPI endpoint/configuration adapter.
- `branch-topology`: provider-backed, read-only PR branch topology analysis.
- `merge-classifier`: provider-neutral, fail-closed merge readiness classification.
- `live-chain-admission`: local validation of repository admission coordinates and policy.
- `flush-lifecycle`: guarded multi-stage flush orchestration and contract validation.
- `template-lifecycle`: template profile/consumer validation and guarded reconciliation.
- `repository-onboarding`: configured, opt-in repository onboarding.

Each entry has a dedicated manifest under `config/engine-manifests/`.
`scripts/validate_engine_manifests.py` validates inventory-to-manifest identity,
interface target existence, declared test-file existence, lifecycle consistency,
known external Origins references, execution modes, dependency references,
and security declarations. Validate Config runs this validator alongside the
Origins parser tests. The branch-topology manifest explicitly records that a
dedicated test module is still outstanding rather than claiming one exists.

This remains an intentionally partial inventory, not a claim that all
workflow files or every script/API subsystem have been catalogued as an engine.
Workflows are grouped into functional boundaries rather than counted as
independent engines. The next inventory passes must classify additional
implementation boundaries, deduplicate shared subsystems, and add manifests
only after ownership, interfaces, dependencies, trust and tests have been
verified. Unknown values must remain explicit rather than guessed.

## Engine integration contract

Every engine should declare its Origins relationship in a machine-readable
engine manifest. Each engine must identify:

- Origins records it consumes or implements;
- the capability it provides;
- provider adapters and supported interfaces;
- required local tools/toolchains and supported platforms;
- inputs, outputs, and reproducibility constraints;
- trust level, permissions, secrets boundary, and network requirements;
- tests and validation evidence;
- whether it is informational, locally executable, or remotely executable.

An engine with no external origin can declare itself original and identify its
internal FSA dependencies. Engines consume the normalized Origins model only
where relevant; an origin reference is not a mandate to execute that project.

## Origins-driven self-build

FSA should progressively build and validate itself from declared, inspectable
contracts:

1. Inventory workflows, scripts, APIs, engines, packages, and tests against
   internal dependencies and external origins.
2. Resolve origin metadata, toolchain versions, licenses, platform constraints,
   and artifact-to-origin links.
3. Plan a deterministic build graph from engine manifests and local dependency
   edges.
4. Build locally with hermetic steps, pinned toolchains, and recorded inputs;
   emit build provenance and artifact digests.
5. Verify outputs, run unit/integration/security checks, and reject undeclared
   network access or dependency drift.
6. Publish only through separately authorized release workflows after checks.

The Origins section is provenance input, not executable build instructions.
A URL or prose attribution cannot safely tell an agent to clone, run, install,
or trust arbitrary code. Build commands, versions, checksums, licenses,
permissions, and network policy must be explicit, reviewed, and independently
validated in dedicated manifests.

## NativeLink's role

NativeLink is recorded in dep-graph/provenance.yml as an optional technical
reference for scripts/nativelink_adapter.py. Its supported REAPI endpoints
are a possible remote execution/cache backend. FSA owns scheduling, engine
selection, policy, provider abstraction, and trust decisions.

NativeLink is not a required dependency for FSA's own build. The initial
adoption path is cache-only and opt-in, followed by a disposable hermetic
workload, then protected remote execution only after TLS/authentication,
namespace isolation, worker properties, quotas, cancellation, and artifact
provenance have been verified. Adding this provenance record configures no
live service or worker.

## Rollout and acceptance criteria

- [x] Add schema and CI validation for the structured Origins and engine manifests.
- [x] Implement a shared read-only Origins parser/normalizer with tests.
- [x] Migrate dependency-graph provenance validation to the shared parser.
- [ ] Migrate README Origins extraction and remaining operational consumers.
- [ ] Complete the inventory of workflows, scripts, APIs, and engine boundaries.
- [x] Add a CI validator for manifest shape, interface/test targets, lifecycle,
      and known Origins references.
- [ ] Generate and validate an internal build graph from declared dependencies.
- [ ] Add hermetic self-build/test targets and build provenance output.
- [ ] Pilot NativeLink cache-only with an authorized disposable deployment.
- [ ] Gate remote execution behind explicit project opt-in and security checks.

The migration must be incremental, backwards-compatible, and fail closed.
