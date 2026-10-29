# Provider-neutral agent runtime contract

**Status:** Contract proposal with a first tested service-boundary implementation on the migration branch. It is not yet wired to the Ona MCP server/workflow and does not claim that another hosted environment is supported.

## Purpose

Separate Fork-Sync-All's portable project intent and agent-facing operations from any one hosted development-environment vendor. A provider adapter may implement only the capabilities its platform genuinely supports. Missing capabilities must be reported as unsupported, not simulated as success.

This contract complements, but does not replace:

- `scripts/includes/platform-adapter.sh`, which abstracts Git hosting operations.
- `scripts/onboard-repo.sh` and `scripts/import-repo.sh`, which onboard/import Git repositories.
- `config/agent-skills.yml`, which describes portable Agent Skills discovery/export.
- The existing Ona project registry, sync script, MCP server, and budget adapter, which remain vendor-specific until an implementation is migrated and verified.

## Layer boundaries

1. **Portable intent and registry** — project key, source repository URL, requested default branch, display name, description, labels, and optional capability preferences. No vendor project IDs, credentials, API URLs, or vendor-specific lifecycle states belong in the portable record.
2. **Provider adapter** — translates portable requests into a provider's API, validates responses, and reports explicit capabilities. It owns vendor IDs and vendor-specific request/response details.
3. **Lifecycle service** — selects a configured adapter, validates requested operations against its declared capabilities, records normalized outcomes, and applies retry/idempotency policy.
4. **Agent/MCP interface** — exposes the normalized lifecycle service to compatible agents. It must not call vendor APIs directly or bypass capability checks.
5. **Budget and execution control** — remain separate capability interfaces. Billing observations must not be confused with allocated budget or remaining balance; pause/resume must not be described as stopping an execution unless the provider guarantees that behavior.

## Minimum adapter interface

An adapter implementation should provide equivalent operations (language-specific names may vary):

- `describe_provider()` — stable provider ID, adapter version, supported capabilities, and authentication requirements (never secret values).
- `validate_config(config)` — reject malformed or ambiguous configuration before network activity.
- `list_projects()` / `get_project(key)` — read-only inventory and lookup.
- `ensure_project(request, idempotency_key)` — create or reconcile a project only when the provider supports it; return a normalized result and provider-owned identifier.
- `get_environment(project_ref, request)` — create or retrieve an environment only when supported and explicitly requested.
- `get_operation(operation_id)` — retrieve normalized operation status where asynchronous operations exist.
- `close()` — release resources and redact secrets from errors/logs.

The adapter must declare capability flags for project creation, project updates, environment creation, environment lookup, environment lifecycle control, execution lookup, goal pause/resume, usage reporting, and remaining-balance reporting. A capability is true only when it is implemented and covered by tests. Unknown capabilities default to unsupported.

## Normalized result shape

Each operation should return a structured result with:

- `ok`: boolean indicating whether the requested operation actually succeeded.
- `provider`: stable provider identifier.
- `operation`: normalized operation name.
- `resource`: normalized resource type and opaque provider reference, if available.
- `status`: normalized lifecycle status, or `unknown` when the provider cannot establish it.
- `capability_supported`: boolean.
- `retryable`: boolean where the failure can be safely retried.
- `request_id`: provider request/trace ID when available and safe to expose.
- `error_code` and `message`: sanitized diagnostic details without tokens, authorization headers, or raw secret-bearing response bodies.

A dry-run result must be clearly marked as simulated and must never be reported as a successful remote mutation. A failed HTTP request must not be converted to an empty success-shaped object.

## Safety requirements

- Default to read-only discovery. Mutations require an explicit caller request and the relevant authorization.
- Never infer a provider from the presence of a secret, and never log secrets.
- Do not pass credentials through shared Dev Container settings unless a specific adapter requires them and the consumer explicitly opts in.
- Validate provider URLs as HTTPS origins or against an explicit allowlist; do not accept credentials embedded in URLs.
- Keep project registry changes, provider API calls, and Git pushes as separate operations. Provider API automation must not silently commit/push registry edits to `main`.
- Use stable idempotency keys where supported; do not blindly retry non-idempotent create operations.
- Validate all user-controlled project keys and resource IDs before building paths or shell commands.
- Keep Git hosting permissions and downstream mirror-write permissions separate from hosted runtime permissions.
- Do not rewrite authentic historical attribution or delete historical migration notes merely to remove vendor names.

## Migration and acceptance gates

1. **Inventory consumers:** identify every caller of the Ona registry, shell operator, MCP tools, billing adapter, environment templates, and workflow before changing their behavior.
2. **Define portable schema:** add a versioned provider-neutral registry with validation and migration tests. Preserve existing project identifiers as adapter-owned mappings until they are safely migrated.
3. **Build one adapter behind the contract:** retain Ona as an explicitly named compatibility adapter while proving the contract with fake-provider tests and the existing integration's regression tests.
4. **Move callers to the lifecycle service:** MCP and workflows consume normalized operations; no caller imports or invokes a provider API directly.
5. **Verify capability parity:** document capabilities that cannot be preserved on another provider. Never claim parity based only on matching method names.
6. **Reconcile configuration and secrets:** remove vendor-only secrets from shared environments and keep adapter-specific secrets scoped to the adapter's execution context.
7. **Regenerate generated docs and run CI:** update source docs first, regenerate generated references with the repository's established tooling, then verify all required checks on the resulting head.
8. **Retire deliberately:** remove the Ona adapter, registry, workflow, and templates only after consumers are migrated or the corresponding capability has an explicit retirement decision. Keep this PR open until review and validation are complete; merging remains a separate maintainer decision.

## Current implementation slice

`scripts/agent_runtime_lifecycle.py` implements a provider-injected service boundary with explicit capability gates, normalized operation results, key validation, sanitized adapter-error handling, and a dry-run path that never calls the mutation adapter. `tests/test_agent_runtime_lifecycle.py` exercises these properties with a fake adapter. The module has no vendor API calls and does not load providers dynamically.

This is intentionally only the first slice: no production adapter is registered, no provider-neutral project registry has been introduced, and the existing Ona MCP server and scheduled workflow still call the legacy implementation directly. The fake-adapter tests prove the service boundary behavior, not end-to-end cloud environment creation.

## Explicit non-goals

This contract does not itself create cloud workspaces, register external projects, provision runners, replace provider APIs, or authorize workflow dispatches, Git pushes, merges, or downstream mirror writes. It is a boundary and acceptance checklist for implementing those behaviors safely.
