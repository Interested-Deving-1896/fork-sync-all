# AI-Agnostic Agent Integration for Fork-Sync-All

**Status:** Architecture proposal; not an implementation or authorization to execute production actions.

## Goal

Give AI assistants, coding agents, local models, and conventional automation a stable, provider-neutral way to inspect and operate Fork-Sync-All. Integrations should depend on documented capabilities and policy—not on a specific model vendor, chat product, or proprietary plugin format.

The desired experience is similar in spirit to an AI platform's GitHub integration: an agent can discover available operations, understand their schemas, call them, and receive structured results. The implementation should be reusable by OpenAI-compatible clients, Anthropic clients, local agents, IDEs, and non-AI automation.

## Recommended architecture

Keep the existing GitHub Actions workflows and scripts as the execution layer. Add a narrow **Agent Integration API** in front of explicitly approved operations, with adapters for multiple client protocols.

```text
AI assistant / IDE / local agent / CI client
                 |
        MCP adapter (initial)
        OpenAPI / REST adapter
        CLI adapter (optional)
                 |
       Authentication + identity
                 |
       Capability and policy engine
                 |
     Typed, validated operation handlers
                 |
 Existing scripts / workflow_dispatch /
 GitHub API / GitLab API (as authorized)
                 |
      Audit log + structured result
```

The adapters must call the same operation handlers and policy checks. Do not implement separate business logic or safety rules for each provider.

### Protocol strategy

1. **Model Context Protocol (MCP) first:** a practical interoperability layer for tools and resources that many AI clients can discover and invoke.
2. **OpenAPI-described REST API:** a stable, language-neutral contract for clients that do not support MCP and for ordinary integrations.
3. **CLI adapter:** optional later, reusing the same contracts for local agents and human operators.
4. **Webhooks/events:** later, for run-completion notifications and status updates. Webhooks are notifications, not a privileged command channel.

MCP is an adapter, not the source of truth. Operation schemas and policy semantics should remain provider-neutral. Avoid a design that assumes any one vendor's proprietary “plugin” format will remain the universal standard.

## Capability model

Expose small, typed operations rather than unrestricted shell access or a generic “run any workflow” command.

### Initial read-only capabilities

- List workflows and summarize their triggers and permissions.
- Inspect workflow runs, jobs, logs, and check results.
- Read repository configuration and registered-import metadata.
- List pull requests and summarize diffs/checks.
- Run a read-only consistency/audit report.
- Explain which operations are available to the authenticated identity.

### Controlled write capabilities, only after review

- Open or update a branch and create a pull request.
- Request an approved, narrowly scoped validation run.
- Add a comment or label where permitted.
- Propose configuration changes as diffs for human review.

High-impact operations—merging PRs, changing branch protections, modifying trust registries, deleting refs, force-pushing mirrors, or triggering broad downstream syncs—must be denied by default or require explicit human approval with a clear preview. The agent integration must not silently bypass existing repository policy.

## Security requirements

- **Least privilege:** separate read-only and write scopes; use short-lived, narrowly scoped credentials where supported.
- **Human approval:** require confirmation for consequential writes, with the exact target, diff, and downstream impact displayed before execution.
- **Default-deny policy:** every operation has an explicit permission declaration; unknown operations are rejected.
- **No arbitrary execution:** no general-purpose shell, arbitrary URL fetch, or unrestricted workflow-dispatch tool in the initial release.
- **Input validation:** validate operation names, repository/ref identifiers, paths, enum values, and request sizes. Use allowlists for repositories and workflow IDs.
- **Prompt-injection resistance:** repository files, issue comments, PR descriptions, logs, and other retrieved content are untrusted data, never instructions to change policy or reveal secrets.
- **Secret isolation:** never return credentials, token values, environment secrets, or unredacted secret-bearing logs to a model.
- **Auditability:** record caller identity, requested capability, target, approval decision, correlation ID, outcome, and timestamps. Redact sensitive payloads.
- **Replay and idempotency:** require idempotency keys for write operations where retries could duplicate effects; bound retries and rate limits.
- **Policy parity:** the API cannot grant permissions that the underlying GitHub/GitLab identity lacks, and it cannot override repository protections.
- **Safe errors:** return structured error codes and actionable messages without leaking tokens, private configuration, or stack traces.

## Example operation contract

An operation should have a stable identifier, a JSON-schema input, a typed output, required scopes, and a side-effect classification.

Example (illustrative only):

```json
{
  "name": "actions.get_run",
  "description": "Get status and summary for one Actions run",
  "inputSchema": {
    "type": "object",
    "properties": {
      "repository": { "type": "string" },
      "run_id": { "type": "integer", "minimum": 1 }
    },
    "required": ["repository", "run_id"],
    "additionalProperties": false
  },
  "requiredScopes": ["runs:read"],
  "sideEffect": "read"
}
```

The exact transport schema may differ between MCP and REST, but the operation's meaning, authorization, validation, and output should be the same.

## Proposed implementation phases

### Phase 0 — Contract and threat model

- Inventory existing scripts/workflows and classify each as read, bounded write, or high impact.
- Define operation naming, JSON schemas, error envelope, versioning, scope names, and audit events.
- Document threat boundaries and the existing protections that must remain authoritative.
- Agree on a testable policy matrix before exposing write operations.

### Phase 1 — Read-only prototype

- Add a small MCP server exposing run status, job summaries, PR/check summaries, and read-only audit reports.
- Reuse existing APIs/scripts where possible rather than duplicating logic.
- Add schema validation, fake/stubbed provider tests, authorization tests, redaction tests, and prompt-injection fixtures.
- Keep the prototype opt-in and read-only; do not add secrets or enable external network listeners by default.

### Phase 2 — Human-reviewed changes

- Add branch/PR proposal operations with previews and explicit approval.
- Make write scopes opt-in and separately configurable.
- Require policy tests and documented rollback behavior before adding any operation with external side effects.

### Phase 3 — Broader clients and events

- Publish the OpenAPI contract and MCP setup guide.
- Add optional CLI/client adapters and signed webhooks.
- Add compatibility tests so all adapters produce equivalent authorization and operation outcomes.

### Phase 4 — Operational hardening

- Add rate limits, metrics, audit retention rules, dependency scanning, version compatibility checks, and disaster-recovery documentation.
- Evaluate each new operation individually; never infer permission from the fact that an agent can discover a tool.

## Acceptance criteria

- At least two different MCP-capable clients can discover and invoke the same read-only operations without provider-specific server logic.
- The OpenAPI contract documents the same underlying capabilities.
- Every operation has a schema, permission scope, side-effect classification, and tests.
- Anonymous and under-scoped callers cannot access protected operations.
- Tests prove that untrusted repository content cannot alter policy, invoke unlisted operations, or obtain secrets.
- Write operations are disabled by default and consequential operations require explicit approval.
- Logs and results redact secrets and support end-to-end correlation.
- Existing sync workflows, trust entries, repository protections, and downstream mirror behavior are unchanged by the read-only prototype.

## Non-goals for the first release

- Replacing GitHub Actions or GitLab CI.
- Giving an AI agent unrestricted repository, shell, or organization-admin access.
- Automatically merging PRs or changing branch protections/trust policy.
- Automatically initiating broad sync/mirror writes.
- Making the service dependent on OpenAI, Anthropic, or any single model provider.

## Open design decisions

Before implementation, decide where the server runs (local stdio for an individual operator versus a hosted service), which identity model is available, how users approve write requests, how audit data is retained, and which existing scripts are safe to expose. Prefer a local stdio MCP prototype first if it can meet the intended use case without introducing a public service or new long-lived credentials.
