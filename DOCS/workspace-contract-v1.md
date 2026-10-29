# Provider-neutral workspace contract v1

**Status:** proposed contract; no backend is authorized or implemented by this document alone.

Schema: `schemas/workspace-contract-v1.schema.json`

## Purpose

Define a stable request/result envelope so Fork-Sync-All can orchestrate different workspace backends without coupling task policy to Incus, Blincus, a Dev Container, or an agent runtime. The contract describes intent and evidence; it is not an authorization mechanism.

## Operations and lifecycle

Supported operation names are `create`, `inspect`, `exec`, `stop`, `preserve`, `destroy`, and `recover`. A backend must reject unknown operations and must not infer authorization from a valid schema document.

Recommended workspace states:

- `requested`: request parsed, not yet authorized or executed.
- `policy_denied`: policy check explicitly denied the operation.
- `accepted`: policy passed and backend accepted the request.
- `running`: workspace/task operation is active.
- `succeeded`: requested operation completed successfully.
- `failed`: operation failed; include bounded diagnostic evidence.
- `cancelled`: operation was cancelled; cleanup and preservation results remain explicit.
- `unavailable`: backend or required prerequisite was observed to be unavailable.
- `unknown`: evidence was missing, timed out, malformed, or inconclusive.

Do not translate missing status, empty evidence, malformed output, or a timeout into success. A successful `create` result does not mean an agent task succeeded; a successful agent exit does not mean cleanup succeeded. Report each lifecycle outcome separately.

## Request rules

- Use separate, generated `task_id` and `workspace_id`; do not key identity only on a repository basename.
- Prefer an immutable 40-character commit SHA in addition to a human-readable ref. Resolve and record the exact commit before checkout.
- Use HTTPS or SSH repository URLs. Credential material must not be embedded in the URL.
- `allowed_environment_names` contains names only, never secret values. Backend code must resolve any approved values through a separate credential policy.
- Resource limits and network policy are requested constraints, not proof that the backend enforces them. Report unsupported controls as `unsupported` or `unknown`.
- `idempotency_key` should make retries safe for the same intended operation. A repeated request must not silently target a different checkout or task.
- `metadata` is for bounded, non-secret correlation data only.

## Security profiles

### `agent-sandbox`

Default for untrusted code and automated agents. Deny or restrict network access explicitly. Do not forward GUI, Wayland/X11, audio, GPU, host-home paths, host UID mappings, nested virtualization, or the Incus administrative socket by default. Mount only a validated task worktree. Never pass the complete host environment to a workspace. The schema constrains requested network policy, but a backend must independently enforce and verify it.

### `interactive-developer`

Optional human-requested profile for developer convenience. GUI/audio/GPU, host mounts, UID mapping, and nesting are elevated host-access grants and must be visible in the effective policy and logs. This profile must not be selected automatically for untrusted PR code.

## Execution and recovery requirements

1. Validate the request and independently authorize the operation before calling a backend.
2. Pass commands as argument arrays, not interpolated shell strings. Apply bounded timeouts and output limits.
3. Canonicalize mount paths; reject root paths, unexpected parent paths, and paths outside the approved checkout.
4. Record backend identity/version, exact source commit, policy profile, capability observations, timestamps, exit status, and cleanup outcome.
5. On cancellation or failure, stop processes safely. Before destruction, inspect for dirty/untracked work and preserve a recovery manifest when policy requires it.
6. Never destroy a workspace containing uncommitted work solely because a task timed out. If state cannot be inspected, fail closed and retain the resource for review rather than assuming it is clean.
7. Treat host configuration, Incus profiles, credentials, and GitHub write permissions as separate permissions. Workspace creation grants none of them implicitly.
8. Keep Git push, PR creation, PR merge, workflow dispatch, and downstream mirror writes behind their own independent authorization gates.

## Capability vocabulary

Each capability uses one of `available`, `unavailable`, `unsupported`, `unknown`, or `requires_policy_review`.

- `available`: positive evidence supports the stated capability in the current observed environment.
- `unavailable`: a required executable/service/prerequisite was observed to be unavailable.
- `unsupported`: the backend explicitly does not implement the capability.
- `unknown`: no reliable observation is available.
- `requires_policy_review`: technically plausible but not approved for use until policy and isolation are reviewed.

A responsive Incus daemon is not evidence that workspace creation, command execution, network isolation, VM isolation, or resource limits are safe.

## Validation and versioning

- This schema uses JSON Schema Draft 2020-12 and is intentionally standard-library/tool neutral.
- Consumers should validate with a Draft 2020-12 validator and add semantic checks for cross-field rules, immutable refs, canonical paths, authorization, and backend-enforced policy.
- Additive fields require a versioning decision; breaking changes require a new contract version.
- Offline contract tests should cover valid requests, unknown operations, invalid IDs/refs, agent profile network constraints, secret-value rejection by application policy, malformed backend responses, timeouts, cancellation, and cleanup failure.
- Live Incus tests must run only on a separately provisioned disposable host with explicit authorization. No live daemon test is implied by schema validation.

## Current implementation boundary

This change adds the contract schema and documentation only. It does not provision or execute workspaces, modify Incus configuration, run agents, change repository settings, dispatch workflows, merge PRs, or write downstream mirrors.
