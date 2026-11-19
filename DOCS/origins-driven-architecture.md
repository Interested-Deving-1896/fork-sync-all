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

- [ ] Add schema validation for provenance and engine manifests.
- [ ] Implement a shared read-only Origins parser/normalizer with tests.
- [ ] Migrate dependency graph and README generation to the shared parser.
- [ ] Add engine manifests and inventory all workflows/scripts/API engines.
- [ ] Add a validator that fails CI when an engine lacks required metadata or
      references an unknown origin.
- [ ] Generate an internal build graph from declared dependencies.
- [ ] Add hermetic self-build/test targets and build provenance output.
- [ ] Pilot NativeLink cache-only with an authorized disposable deployment.
- [ ] Gate remote execution behind explicit project opt-in and security checks.

The migration must be incremental, backwards-compatible, and fail closed.
