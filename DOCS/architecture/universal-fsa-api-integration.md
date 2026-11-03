# Universal FSA API Integration Mandate

## Status and intent

This document establishes the platform-wide architecture contract for Fork-Sync-All (FSA). It is a target-state mandate and migration plan, not a claim that the repository has already completed the migration.

**FSA API is the canonical internal integration, orchestration, and capability boundary for Fork-Sync-All.** Existing and future subsystems must use shared FSA contracts for cross-cutting platform capabilities instead of creating parallel provider clients, credential handling, quota logic, lifecycle state, retry logic, or execution dispatch implementations.

The mandate applies to the whole repository: shell scripts, Python tools, workflow automation, FSA API adapters, project creation, synchronization/mirroring, lifecycle management, dashboards, agent workflows, and future components.

## The key distinction: canonical interface does not mean HTTP everywhere

All components should depend on the same FSA API contracts, but an internal function call does not need to make an HTTP request.

- In-process callers may use a versioned FSA core library/interface.
- Remote clients and independently deployed components may use the FSA HTTP API.
- Both transports must implement the same schemas, capability semantics, policy checks, error taxonomy, and idempotency rules.
- Provider and execution implementations remain behind adapters selected through explicit capability and policy decisions.

This avoids turning local operations into needless network calls while preventing each subsystem from inventing its own integration rules.

## Target architecture

```text
CLI / workflows / scripts / project factory / sync / agents / UI
                         |
             versioned FSA contracts
                         |
      FSA API core: policy, orchestration, state, audit
             /                         \
    provider capability ports     execution capability ports
             |                         |
    Git hosting adapters          runner/agent adapters
             |                         |
 GitHub / GitLab / Gitea /        Actions / GitLab CI /
 Forgejo / Codeberg / others      OpenCode / ChatGPT Remote /
                                 local and remote runners
```

The provider plane and execution plane are independent. A healthy Git provider connection does not imply that an execution transport is available, and an unavailable ChatGPT connector must not be reported as a GitHub API quota failure.

## Mandatory shared capabilities

The FSA core must own or expose one canonical contract for:

1. **Provider connectivity:** provider identity, canonical host, authentication state, health, namespace model, and supported operations.
2. **Provider operations:** projects/repositories, refs, branches, commits, contents, pull/merge requests, reviews, issues, releases, webhooks, and workflow metadata where supported.
3. **Capability discovery:** explicit supported/unsupported/unknown states backed by adapter evidence; never infer support from provider names alone.
4. **Credential use:** consume runtime-supplied credentials, apply least-privilege expectations, redact them, and report missing/insufficient permissions. Never create tokens, broaden scopes, or persist secrets automatically.
5. **Quota and budgets:** provider API rate limits, per-resource buckets, connector execution limits, and runner capacity as distinct measurements. Unknown values remain unknown, never unlimited.
6. **Execution:** transport discovery, dispatch, bounded work scheduling, cancellation, result collection, and normalized execution status.
7. **Lifecycle and durable state:** operation identity, journal, checkpoints, idempotency keys, resume, and reconciliation of ambiguous external writes.
8. **Policy and safety:** dry-run/preview, approval gates, protected-target rules, mutation scopes, and explicit fallback authorization.
9. **Diagnostics and audit:** sanitized structured errors, correlation IDs, timestamps, provenance, and actionable remediation without leaking secrets or raw sensitive provider responses.
10. **Compatibility:** versioned schemas, capability negotiation, stable error codes, deprecation windows, and compatibility tests.

## Non-negotiable integration rules

- A subsystem must not introduce a second provider API client or a private copy of shared authentication, quota, retry, pagination, lifecycle, or journal behavior.
- If a required capability is missing, add it to the FSA contract and implement it behind the relevant adapter; do not create a competing subsystem API.
- Provider-specific code is permitted only inside provider adapters or narrowly scoped compatibility shims.
- Execution-provider code is permitted only inside execution adapters.
- Consumers must not inspect provider-specific response bodies to make policy decisions when a normalized FSA field exists.
- No silent provider or execution-transport switching for mutations. Fallback requires compatible capabilities, the same durable operation identity, and explicit policy authorization.
- A timeout after a write is ambiguous. Reconcile remote state before retrying.
- Preserve existing behavior during migration where safe; use compatibility wrappers and deprecation notices rather than a flag-day rewrite.
- No credentials, token scopes, protected environments, repository settings, or production resources may be changed as part of routine migration without explicit authorization.

## Repository audit: confirmed migration targets

The following are concrete findings from a repository code-search audit. This is a targeted initial inventory, not a claim that every call site has been enumerated.

| Area | Observed implementation | Required direction |
| --- | --- | --- |
| `fsa-api/core/lib/fsa-adapter.sh` | Sources the shared platform adapter but also defines GitHub-specific `fsa_api_get/post/patch/delete` and GraphQL helpers. | Make FSA provider operations delegate to normalized provider ports; retain GitHub GraphQL only as an explicit GitHub adapter capability. |
| `fsa-api/core/adapters/**` | Many endpoint adapters call `fsa_api_get` directly. | Keep endpoint adapters thin; route through the FSA core provider service and normalized errors. |
| `scripts/includes/gh-api.sh` | Shared GitHub-specific REST client exists. | Keep as a compatibility/implementation layer for the GitHub adapter; prevent new consumers from depending on it directly. |
| Standalone scripts | Search found direct `curl` calls to `api.github.com`/GitHub endpoints in scripts such as `import-repo.sh`, `vouch-onboard.sh`, `cleanup-pollution.sh`, `create-readmes.sh`, `pin-issues.sh`, `runner-status.sh`, `inject-badges.sh`, `pin-version.sh`, `notifications.sh`, and `create-arch-repos.py`. | Migrate cross-cutting Git-provider operations to FSA contracts in small, testable groups. Preserve provider-specific functionality inside adapters. |
| Sync scripts | Several sync scripts source `scripts/includes/platform-adapter.sh` directly. | During migration, make the FSA core the consumer-facing facade; keep the existing adapter as an implementation dependency until the transition is complete. |
| `fsa-api/README.md` and `AGENTS.md` | Documentation still describes GitHub-specific quota behavior and direct adapter use in places. | Update docs alongside behavior; document the canonical entry points and supported compatibility period. |

The audit also found an important distinction: direct provider API calls are not all inherently wrong. Calls inside the provider adapter, low-level transport, or explicitly isolated bootstrap/diagnostic tools may be valid. The boundary is whether a general subsystem independently implements provider behavior instead of using the FSA contract.

## Migration plan and ordering

The migration is incremental and must not delay the already-established priority of completing the Project Creation Engine with passing tests and verified repository creation.

### Stage 0 — Establish the contract and baseline

- Adopt this mandate.
- Inventory direct provider clients, duplicated retry/quota logic, and direct execution dispatch.
- Classify each finding as adapter implementation, approved bootstrap exception, or consumer bypass.
- Define versioned provider, execution, operation, diagnostic, and error schemas.
- Record baseline exceptions so later enforcement is measurable.

### Stage 1 — Canonical provider service

- Build on `scripts/includes/platform-adapter.sh`; do not create a competing adapter.
- Expose normalized provider operations through FSA core library functions and HTTP routes.
- Remove GitHub-only assumptions from shared FSA lifecycle helpers.
- Preserve GitHub-only operations as declared capabilities, not generic operations.
- Ensure failures, empty inventories, permission errors, and unknown quota are distinguishable.
- Add shared offline contract tests for GitHub, GitLab, Gitea, Forgejo, and Codeberg.

### Stage 2 — Project Creation Engine integration (highest implementation priority)

- Route template registry resolution, project creation, initialization, verification, and cleanup through the canonical FSA contracts.
- Reuse the existing durable journal/idempotency/checkpoint system; do not add a second store.
- Make every external mutation resumable and reconcilable.
- Keep live creation opt-in, protected, disposable, and cleanup-verified.
- Require Actions-hosted live tests only when the protected environment and disposable target have been explicitly configured.

### Stage 3 — Migrate consumers by subsystem

Recommended sequence after the project-creation acceptance gate:
1. FSA endpoint adapters and CLI.
2. Repository/project sync and mirror operations.
3. Issues, pull/merge requests, reviews, and notifications.
4. Workflow dispatch/status and runner capacity.
5. README/docs automation and maintenance scripts.
6. Dashboards, agent tools, and external integrations.

Each migration should remove a duplicated implementation or explicitly justify retaining it as an adapter/compatibility shim.

### Stage 4 — Execution and agent neutrality

- Add a separate execution-transport registry with capability and health contracts.
- Support GitHub Actions, GitLab CI, OpenCode, ChatGPT Remote, and local/remote runners through adapters where their documented interfaces permit.
- Separate transport quotas, concurrency, queue depth, and health from Git-provider API quota.
- Reuse durable operation IDs, checkpoints, and policy gates across transports.
- Never imply that a connector or agent can be invoked when its connection or execution capability is not actually available.
- Keep agent protocol/provider integrations replaceable and avoid treating any single agent vendor as foundational.

### Stage 5 — Enforce the boundary

Add CI checks that:
- Detect new direct provider API clients outside approved adapter/transport directories.
- Detect direct secret/token handling and duplicated retry/quota/pagination helpers in consumer code.
- Require adapter contract tests for every provider.
- Require API schema compatibility tests for every FSA contract change.
- Require idempotency/reconciliation tests for externally visible mutations.
- Maintain a reviewed, expiring exception manifest for unavoidable legacy/bootstrap paths.
- Report existing violations as a migration backlog initially; do not make CI permanently green by silently allowlisting the whole repository.

## Error and state model

The normalized contract must distinguish at least:

- `unauthenticated`, `unauthorized`, `insufficient_scope`
- `not_found`, `conflict`, `validation_failed`
- `rate_limited`, `temporarily_unavailable`, `transport_error`
- `unsupported_capability`, `malformed_response`, `unknown_outcome`
- `policy_blocked`, `approval_required`, `cancelled`

An empty successful list is different from a failed request. A missing quota observation is `unknown`, not zero and not unlimited. A mutation whose response was lost is `unknown_outcome` until reconciliation resolves it.

## Definition of done

The mandate is fulfilled only when:

- Every general-purpose subsystem uses the canonical FSA contracts for shared platform capabilities.
- Provider-specific implementations are confined to provider adapters and approved compatibility/bootstrap exceptions.
- Execution transports are independent of provider adapters and have their own capability/health/quota models.
- All supported providers pass the same contract suite.
- Project creation is verified end-to-end with protected, disposable live testing in addition to deterministic offline tests.
- Durable state, idempotency, and ambiguous-write reconciliation cover every external mutation.
- CI enforces the boundary and the exception list is narrow, reviewed, and time-bounded.
- Documentation, CLI, workflows, and agent integrations use the same versioned contracts.

Until those criteria are met, FSA should describe itself as **migrating toward universal FSA API integration**, not as already fully unified.


## Federated Dual API and project-branded derivatives

### Upstream/downstream relationship

The canonical dependency direction is:

```text
UAAPI (upstream, provider-neutral API foundation)
  ├── FSA-API (downstream specialization for Fork-Sync-All)
  │     └── project-specific FSA policy/configuration extensions
  └── Project UAAPI derivatives (optional, namespaced extensions)
        └── Project FSA-API derivatives (optional, built on that project's UAAPI)
```

**UAAPI is the upstream foundation; FSA-API is a downstream derivative/specialization of UAAPI.** This relationship must be represented explicitly in repository metadata and dependency manifests, rather than inferred from directory names or branding. The existing `fsa-api/uaa/` directory is the current embedded UAA/UAAPI implementation lineage; its historical name does not reverse the dependency direction. The standalone `unified-agnostic-api` source repository is the upstream project to reconcile with that embedded copy.

FSA-API may contribute reusable improvements upstream only through an intentional upstream change. The downstream FSA specialization may add repository governance, project policy, workflow orchestration, lifecycle and template-registry capabilities, but must not make UAAPI depend on FSA.

### Project-owned variants are supported

Any Interested-Deving-1896 source repository may opt into a branded derivative pair when it has a real project-specific need:

- a project UAAPI derivative, based on and compatible with canonical UAAPI;
- an optional project FSA-API derivative, based on that project's UAAPI and compatible with canonical FSA-API contracts.

A project may adopt only the UAAPI derivative, only the FSA specialization where its dependency is satisfied, or both. A pair is not mandatory for every repository. Do not create empty API copies merely to satisfy naming symmetry.

Namespacing is metadata, not a new protocol. A project may use a short prefix or suffix derived from its canonical repository/project identifier (for example, `ies-uaapi` and `ies-fsa-api`), while retaining canonical API identifiers, schema identifiers, capability names, and version negotiation. HTTP route prefixes may be branded (for example, `/api/ies/...`), but must not alter shared payload semantics.

### Inheritance, extension and compatibility rules

1. **Upstream contracts are immutable from the consumer's perspective.** Project variants may add namespaced optional capabilities, schemas, routes and policy profiles; they may not silently redefine or remove canonical fields, errors, lifecycle semantics or security requirements.
2. **Explicit dependency metadata is required.** Each derivative declares upstream repository, upstream API family, compatible contract range, pinned release/tag or commit, local variant identifier, and extension points.
3. **Capability negotiation is mandatory.** Consumers discover supported, unsupported and unknown capabilities. They must not infer compatibility from a brand name, version string alone, or the presence of a route.
4. **Compatibility is testable.** Every derivative runs canonical upstream contract tests plus project extension tests. Breaking changes require a major contract version and a documented migration window.
5. **No private copies of shared behavior.** Shared auth, credential handling, provider operations, retry, quota, durable operation identity, idempotency, audit and error normalization remain upstream-owned. Project-specific policy belongs in FSA-API extensions; provider/execution implementations remain behind adapters.
6. **Local autonomy is preserved.** Projects own their branding, configuration, extension modules, policy profiles and release cadence within the compatibility contract. Upstream updates are proposed and adopted deliberately; no unreviewed forced overwrite of project-owned API code.
7. **No transitive circular dependency.** UAAPI must never depend on FSA-API. A project FSA derivative depends on its project UAAPI derivative, which in turn declares its canonical UAAPI base.
8. **Security cannot be weakened by branding.** Project variants inherit authentication, authorization, secret-redaction, least-privilege, approval, audit and fail-closed requirements. A project may strengthen policy, not weaken canonical minimums.

### Canonical responsibilities

| Layer | Owns |
| --- | --- |
| UAAPI | Provider-neutral API primitives, capability discovery, adapter contracts, normalized transport/errors, common schemas and compatibility negotiation |
| FSA-API | FSA repository/project policy, validation profiles, workflow orchestration, lifecycle, template registry and governance |
| Project UAAPI derivative | Project-owned adapters and optional capabilities built on UAAPI |
| Project FSA-API derivative | Project-specific governance/orchestration extensions built on the project UAAPI and canonical FSA contracts |
| Source repository | Domain-specific business logic and checks that are not reusable API capabilities |

Execution-provider/runner transport remains a distinct capability plane; project branding must not couple UAAPI to a particular forge, CI vendor, AI agent or runner.

### Registry and scaffold requirements

The template/consumer registry should support opt-in declarations rather than propagating executable API implementations indiscriminately. A derivative manifest should record at least:

- `variant_id`, `display_name`, `repository`, `api_family` (`uaapi` or `fsa-api`);
- `upstream.repository`, `upstream.api_family`, `upstream.contract_range`, `upstream.ref`;
- `parent_variant` where an FSA derivative is based on a project UAAPI variant;
- `namespace.prefix`, `namespace.route_prefix`;
- `capabilities.provided`, `capabilities.required`;
- `compatibility.test_profile`, `ownership`, `update_policy`.

The scaffold must offer a preview/dry-run, validate names and paths, refuse to overwrite existing project-owned files, generate the dependency manifest and contract-test harness, and produce a reviewable change. It must not silently enable routes, expose an unauthenticated network service, create credentials, or mutate remote repositories.

### Migration from the existing consumer scaffold

The current `fsa-api/scripts/scaffold-consumer.sh` and `fsa-consumer.yml` provide a branded route layer served alongside FSA. That is useful for route extensions but is not, by itself, a standalone UAAPI/FSA-API derivative system. Evolve it in stages:

1. Preserve the existing consumer route mode as a compatibility feature.
2. Add explicit `uaapi-derivative` and `fsa-derivative` scaffold modes with dependency metadata and contract tests.
3. Separate standalone project API packaging from the optional co-hosted route extension.
4. Reconcile the embedded `fsa-api/uaa/` tree against the canonical `Interested-Deving-1896/unified-agnostic-api` source before changing propagation or deleting duplicate files.
5. Add registry validation and CI checks for dependency direction, contract compatibility, ownership and forbidden circular imports.
6. Pilot the pattern in the Incus Engine Subsystem only after the current BDFS phase and Incus source audit sequencing permits it; then onboard other source repositories by capability and need.

The existing scaffold currently has an implementation hazard: `fsa-start.sh` reads `FSA_CONSUMER_CFG` before assigning its default, and the generated consumer adapter sources the FSA-specific adapter rather than a UAAPI-only contract surface. Correct these as part of the staged implementation with focused tests; do not claim the current scaffold is already safe for standalone derivatives.

### Definition of done for federated derivatives

- UAAPI is demonstrably upstream of FSA-API in code, metadata, documentation and dependency tests.
- The embedded UAAPI copy and standalone UAAPI source have a verified synchronization/provenance relationship.
- A project can scaffold a namespaced UAAPI derivative and optional FSA derivative without copying unrelated FSA control-plane internals.
- Derivatives pass canonical contract tests and their own extension tests.
- Version/capability negotiation, update policy and project ownership are machine-validated.
- Existing consumers remain functional throughout migration; no mirror propagation occurs until all source-repository audits and resolutions are complete.
