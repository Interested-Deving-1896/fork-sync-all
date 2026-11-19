# Origins-first Agent Preflight contract (v1)

**Status:** contract proposal; not a production interception layer.

This contract lets an AI agent request deterministic Origins context before selecting or invoking its own model. It is provider-neutral and read-only. It is designed to build on the shared parser introduced by [PR #1054](https://github.com/Interested-Deving-1896/fork-sync-all/pull/1054), not to duplicate that parser.

## Contract

The JSON Schema in `schemas/origins-agent-preflight-v1.schema.json` defines two messages:

- `preflight_request`: task intent, target repository/revision, optional agent identity/capabilities, and explicit context/cost ceilings.
- `preflight_response`: status and coverage, evidence with trust labels and source locators, a bounded context package, a budget recommendation, unresolved questions, and authority boundaries.

The response must distinguish declared, observed, inferred, human-approved, contradicted, stale, incomplete, inaccessible, and unknown evidence. A missing source is not evidence that no relationship exists.

## Required execution order

1. Detect that a supported agent task touches FSA or a registered FSA-managed target.
2. Submit the request before model selection/invocation where the agent adapter permits it.
3. Run local deterministic Origins resolution first. Network reads are disabled unless explicitly requested and allowed by policy.
4. Enrich from Code Archaeology or canonical linkage/topology sources only through their read-only contracts and only when available.
5. Deduplicate and revision-pin evidence. Return references and bounded excerpts; do not embed entire histories by default.
6. Consult canonical agent-cost profiles and the existing budget/quota authorities. Do not create a competing budget ledger.
7. If deterministic evidence answers the task, return `deterministic_only`. Otherwise, return a budget recommendation; the adapter, not Origins, decides whether an eligible model call can proceed under policy.
8. Treat agent-generated findings as untrusted proposals for review. Never write them directly into authoritative Origins records.

## Budget semantics

- `max_context_bytes` is a hard response-size ceiling.
- `max_estimated_tokens` is a ceiling on a conservative estimate unless an exact supported tokenizer is available.
- `max_model_cost_usd` is a caller-supplied ceiling, not a substitute for the canonical account/provider budget authority.
- `estimated_cost_usd` must be null when price or usage inputs are unknown. Never present estimates as actual charges.
- `actual_usage_known` is false in a preflight response; actual usage is only known after a provider returns trustworthy telemetry.
- Workflow elapsed-time/quota budgets and model token/cost budgets remain separate dimensions.
- No silent paid-model fallback, provider change, or credential-class change is permitted.

## Authority and safety

Preflight is not authorization. It cannot approve provenance, license compatibility, repository admission, writes, merges, branch rewrites, workflow dispatches, mirror propagation, or deployments. Origins remains authoritative for provenance declarations and decisions; Code Archaeology owns historical observations; linkage/topology registries own their respective graph domains. Evidence exchange does not confer write authority.

If preflight is unavailable or partial, the response must say so. High-risk adapters may be configured to stop rather than bypass it. Unrelated conversations must not be intercepted.

## Implementation sequence

1. Land and review the shared Origins parser foundation in #1054.
2. Recover and verify the closed/unmerged Code Archaeology work in #989/#991 before claiming that enrichment is available.
3. Implement the request/response validator and offline deterministic resolver.
4. Add a budget adapter over `config/agent-cost-profiles.yml` and canonical usage/quota sources.
5. Add deterministic-only and hard-budget-stop tests.
6. Add one reference agent adapter, then conformance tests for every supported adapter.
7. Keep live interception, paid model calls, credentials, production dispatch, and writes behind existing independent policy gates.

## Current limitations

This document and schema define the interface only. They do not claim that any agent currently invokes preflight, that token-level budget enforcement is live, or that Code Archaeology evidence is integrated on the default branch.
