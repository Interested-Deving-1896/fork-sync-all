# Keep-Alive Runner Reuse Audit: AI Agent Runtime

**Status:** implementation-planning audit; no host provisioning, agent session, or provider integration is implemented by this document.

## Executive finding

Fork-Sync-All already has useful control-plane building blocks for a provider-neutral agent runtime, but the current runner-status workflow is not itself a persistent runner or desktop-host manager. Reuse its lifecycle, quota, capacity, and observability patterns; do not treat queue monitoring or a GitHub Actions runner as a persistent ChatGPT Remote host.

The first implementation should be a small, testable runtime contract and read-only capability/status path. Provisioning and mutating controls should follow only after a supported host/provider adapter and explicit authorization model are verified.

## Existing building blocks and limits

| Existing component | Reuse opportunity | Boundary / gap |
|---|---|---|
| `.github/workflows/runner-status.yml` | Scheduled/manual report pattern, scoped permissions, concurrency, quota pre-flight, step summaries | Observes GitHub Actions activity and publishes capacity; it does not keep a desktop session or host alive. |
| `scripts/runner-status.sh` | Queue-depth aggregation, configurable thresholds, structured workflow outputs | It currently emits `healthy=true` when quota is too low or the organization Actions endpoint is unavailable. Those paths mean “not observed,” not “verified healthy”; downstream consumers must not treat them as a successful health observation. |
| `scripts/forge-capacity-observe.py` | Provider-aware capacity observation, timestamps, source/confidence metadata, stale-run filtering | Observed GitHub Actions job capacity is not equivalent to available interactive desktop/agent capacity. Its scan errors must remain visible and must not be silently represented as a fresh successful snapshot. |
| `scripts/includes/quota-snapshot.sh` and quota instrumentation | Admission control and API-budget awareness | API quota is only one resource dimension; agent runtime budget, host availability, disk, and provider limits need separate signals. |
| `scripts/includes/platform-adapter.sh` | Pattern for a provider/forge-neutral capability boundary | Git forge adapters and AI-agent lifecycle adapters are different interfaces; avoid conflating them. |
| Agent Skills and safe Git workspace work (PRs #699/#834 and related workspace work) | Portable, constrained repository operations in a local execution environment | Workspace safety does not provision a persistent host, launch a provider session, or expose ChatGPT Remote controls. |
| Provider-neutral integration proposals (PRs #717/#718) | Shared operation contracts, capability allowlists, approval model, MCP/API adapter strategy | These are architecture proposals, not a deployed agent server. Reconcile rather than create a competing API. |
| Provider-neutral migration/runtime contract work (PR #882) | Lifecycle adapter contract, normalized capabilities/results, migration gates | Contract proposal only; provider-specific lifecycle implementations remain to be audited and tested. |

## Proposed target boundary

Keep four responsibilities separate:

1. **Runner and host supervisor** — manages a supported execution host's availability, heartbeat, resource limits, restart policy, and lifecycle. A GitHub Actions runner can be one execution target, not an assumed always-on desktop.
2. **Agent runtime adapter** — implements only provider-supported operations such as discover capabilities, start/inspect a session, send a task, request cancellation, and report terminal state. Unsupported operations must return an explicit unsupported result.
3. **Shared policy and task contract** — validates inputs, enforces least privilege, records audit events, redacts secrets, applies idempotency/timeouts, and requires approval for sensitive writes.
4. **Repository/workspace adapter** — uses the existing safe Git workspace capabilities and Fork-Sync-All repository automation to prepare reviewable changes without implicitly pushing, merging, or writing downstream mirrors.

ChatGPT Remote should be treated as a first integration target only after its supported host and connection requirements are confirmed. Do not infer a public API for controlling ChatGPT Remote from the mobile screen or from the existence of GitHub Actions. If a supported direct integration is unavailable, the first proof of concept should target a compatible Codex/agent execution environment and document the distinction honestly.

## Required health model

Do not collapse “not checked” into “healthy.” The runtime should distinguish at least:

- `healthy`: a fresh observation verified required checks;
- `degraded`: the runtime is reachable but one or more non-fatal checks failed;
- `unavailable`: a required endpoint/host is confirmed unreachable;
- `unknown`: observation was skipped, incomplete, stale, or failed before a trustworthy conclusion.

Keep queue health, runner capacity, host reachability, provider session state, and budget/quota as separate signals. A single summary may aggregate them, but it must preserve the underlying status and observation timestamp/source. In particular, the existing `runner-status.sh` quota-low and inaccessible-org branches must not be interpreted as a positive health check.

## Delivery sequence and acceptance gates

### 1. Reconcile the existing PR stack

Review #882 together with #717/#718 and #699/#834. Select one canonical shared operation/agent contract, keep provider-specific APIs behind adapters, and identify which workspace implementation is canonical. Do not merge overlapping alternatives independently or claim the runtime is deployed while the work remains proposal-only.

### 2. Harden observation semantics

Add tests for quota-low, inaccessible endpoint, malformed/incomplete response, partial pagination, stale observations, and verified healthy/critical queue states. Ensure skipped or incomplete scans produce an explicit unknown/unavailable result and cannot publish a fresh-looking capacity snapshot. Preserve compatibility only where consumers are audited and safe.

### 3. Implement read-only runtime discovery

Add a provider-neutral status/capability contract and one read-only adapter. Include provider name/version, supported capabilities, host/session identifiers, observed-at timestamp, confidence, status, and sanitized diagnostics. Unknown capabilities must fail closed.

### 4. Add a sandboxed proof of concept

Use a supported Linux development environment or other verified host. Demonstrate repository read/status/diff and a test command against a disposable workspace. No implicit push, merge, destructive Git operation, downstream mirror write, or repository-settings change.

### 5. Add controlled lifecycle operations

Only after read-only tests pass, add start/stop/task operations where the selected provider officially supports them. Require scoped credentials, explicit authorization, bounded timeouts, idempotency, audit events, resource limits, and human approval for repository writes.

### 6. Validate and document

Run offline tests and the repository's applicable CI on the exact PR head. Report actual check conclusions, not expected checks. Keep changes in focused branches/PRs; do not manually dispatch workflows, change settings/secrets, write downstream mirrors, or merge without the separately applicable authorization.

## Definition of done

- A documented mapping from existing runner components to runtime responsibilities.
- Health semantics distinguish verified health from skipped/unknown observations.
- One tested, read-only provider adapter and a disposable-workspace proof of concept.
- A capability matrix that explicitly identifies unsupported ChatGPT Remote operations.
- Tests for failure, stale data, authorization, and secret redaction.
- No provider-specific code in the shared runtime core.
- No merges, settings/secrets changes, manual workflow dispatches, or downstream writes performed as part of this work without separate authorization.
