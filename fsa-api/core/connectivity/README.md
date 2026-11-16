# Git connectivity and execution engine

## Status

This document defines the target architecture and implementation boundary. It is
not a claim that automatic credential provisioning, connector quota control, or
cross-transport failover is already implemented.

## Goals

Fork-Sync-All needs one provider-neutral connectivity contract for Git hosting
and a separate execution contract for the agents/runners that perform work.
These are related control planes, not interchangeable APIs.

### Git provider plane

The provider plane discovers and validates a configured forge, exposes its
capabilities, and reports connection state. The first adapter set is GitHub,
GitLab, Gitea, Forgejo, and Codeberg through the existing
`scripts/includes/platform-adapter.sh` interface.

It must:
- Normalize provider identity, canonical host, API base, namespace model,
  supported operations, and capability evidence.
- Validate only credentials supplied at runtime. Report missing credentials
  and insufficient scopes; never create tokens, widen scopes, or persist
  secrets automatically.
- Distinguish unauthenticated, unauthorized, rate-limited, unavailable,
  unsupported, malformed-response, and healthy states.
- Preserve HTTP status and rate-limit/reset metadata. An empty response is not
  evidence of success or of a missing project.
- Represent unknown quota/capacity as unknown. Never convert missing telemetry
  into unlimited capacity or a fabricated high quota.
- Keep provider-specific behavior behind adapters; consumers use normalized
  project, ref, review, workflow, and rate-limit capabilities.

### Execution plane

The execution plane chooses an available execution transport independently of
the Git provider. Candidate transports include GitHub Actions, GitLab CI,
OpenCode, ChatGPT Remote, and local or remote agent runners. Availability of a
GitHub API connection does not imply that a ChatGPT connector invocation is
available, and connector execution limits must not be misreported as GitHub
API rate limits.

It must:
- Advertise transport capabilities and bounded execution limits.
- Schedule work in bounded, resumable batches.
- Persist checkpoints and idempotency keys before externally visible actions.
- Classify retryable, terminal, ambiguous, and policy-blocked outcomes.
- Resume only from durable checkpoints; reconcile ambiguous mutations before
  retrying them.
- Expose transport health separately from provider health.

## Shared normalized connection record

A connection observation should include:

| Field | Meaning |
| --- | --- |
| `provider_id` | Stable adapter identifier, e.g. `github` or `gitlab` |
| `canonical_host` | Validated forge origin |
| `api_base` | Provider API root |
| `auth_state` | `valid`, `missing`, `invalid`, `insufficient`, or `unknown` |
| `health_state` | `healthy`, `degraded`, `unavailable`, or `unknown` |
| `capabilities` | Explicit supported operations and evidence |
| `quota` | Remaining, reset time, source, observation time; nullable |
| `last_checked_at` | UTC observation timestamp |
| `diagnostics` | Sanitized error category and remediation hint |

Never include tokens, authorization headers, clone URLs containing credentials,
raw provider error bodies, or secret values in this record.

## Failure and recovery rules

1. Fail closed when provider identity, host, authentication, or capability
   evidence is ambiguous.
2. Do not silently switch providers or transports for a mutating operation.
   A fallback requires compatible capabilities, the same durable operation
   identity, and policy approval.
3. Retry only classified transient failures, with bounded exponential backoff
   and provider reset metadata when available.
4. Treat timeouts after a mutation as ambiguous. Reconcile remote state before
   any retry; do not blindly repeat repository creation, publication, or merge.
5. Unknown quota is not zero and is not unlimited. A caller must choose an
   explicit conservative policy for operations that need a quota guarantee.
6. Redact secrets and provider response payloads from logs and persisted state.

## Implementation sequence

1. **Normalize current adapter behavior.** Audit and test `pa_init`,
   `pa_api_get`, pagination, HTTP status handling, and rate-limit parsing.
   Remove silent success/fallback paths from callers without breaking the
   legacy compatibility surface.
2. **Add connection diagnostics.** Implement a read-only probe that validates
   configured provider/host and reports sanitized auth, health, capability,
   and quota observations.
3. **Add execution-transport registry.** Define capability discovery and
   normalized health for Actions, CI, remote agents, and local runners.
4. **Add scheduler and durable checkpoints.** Reuse existing idempotency and
   journal primitives rather than creating a second persistence mechanism.
5. **Integrate consumers incrementally.** Migrate FSA API, project creation,
   mirror, workflow, and agent subsystems to the normalized contract.
6. **Run live verification only through explicit protected, disposable
   environments.** Mocked contract tests remain the default; live credentials
   and resource creation are never inferred or provisioned by the engine.

## Relationship to existing work

This is an integration layer over existing components, not a competing second
platform adapter. It should reuse `scripts/includes/platform-adapter.sh`,
`fsa-api/uaa/`, the project-creation journal, and existing quota/checkpoint
helpers. The current FSA lifecycle wrapper still contains GitHub-specific API
helpers and best-effort initialization behavior; those are migration targets,
not proof that the normalized engine is complete.

## Acceptance criteria

- All supported provider adapters pass the same offline contract suite.
- Invalid/missing credentials and unsupported operations are explicit states.
- HTTP 401/403/404/429/5xx and malformed/empty bodies remain distinguishable.
- Rate-limit values are nullable and carry source/reset metadata.
- No missing quota/capacity value is represented as unlimited.
- Provider and execution-transport health can differ without conflation.
- Interrupted operations resume from durable checkpoints and ambiguous writes
  are reconciled before retry.
- Logs and durable records contain no credentials or raw secret-bearing URLs.
- Live tests are opt-in, protected, disposable, and have verified cleanup.
