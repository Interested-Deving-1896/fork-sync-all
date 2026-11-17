# FSA Agent Accountability & Review Governance

## Purpose

The Agent Accountability & Review Governance subsystem defines a provider-neutral contract for evidence accompanying agent-assisted contributions. It coordinates existing FSA controls rather than replacing them: PR Gate, Vouch checks, CI, agent skills, budget/cost tracking, audit/log retrieval, and the FSA-API governance boundary.

The goal is to reduce reviewer reconstruction work by presenting attributable, current, machine-readable evidence before a human review decision.

## Architecture and responsibility

1. **Contribution author / accountable human** — remains responsible for the contribution, its scope, declarations, and responding to review.
2. **Provider-neutral agent execution** — agents may plan, implement, test, document, and assemble evidence through common contracts.
3. **Evidence collector** — records repository/PR/commit identity, agent/provider identity, ordered provenance events, validation results, test outcomes, and risk indicators.
4. **Readiness evaluator** — validates the evidence contract, checks required validations against the exact PR head commit, evaluates freshness and risk, and reports missing or failed evidence.
5. **Existing FSA governance** — Vouch, PR Gate, repository-specific CI, CODEOWNERS, branch protection, and FSA-API remain authoritative for their respective controls.
6. **Human reviewer / maintainer** — alone makes review and merge decisions under repository policy.

Agents may recommend readiness; they cannot approve a PR, merge it, bypass branch protection, authorize protected writes, or change governance policy.

## Version 1 evidence contract

The canonical JSON Schema is `config/schemas/agent-contribution-evidence.schema.json`. Policy defaults are in `config/agent-accountability-policy.yml`.

The contract captures:

- stable evidence ID and creation timestamp;
- repository and pull request identity, including base/head refs and exact head SHA;
- accountable human login;
- provider-neutral agent identity, optional model/version/session;
- change summary, scope, changed paths, and breaking-change declaration;
- ordered provenance events with actor type and action;
- validation checks, their status, completion time, commit SHA, and optional run URL;
- test outcomes;
- risk level and explanatory factors; and
- optional provider-native resource usage/budget observations.

A `human_review` object is an untrusted claim/reference supplied with the evidence. Schema validation cannot authenticate its author or prove that a GitHub review occurred. Any consumer that displays or relies on this field MUST independently retrieve the referenced GitHub review and verify the reviewer login, review state, target PR, and reviewed commit SHA. An agent's readiness report is never a review decision, and this evaluator does not grant authority based on `human_review`.

## Readiness rules

The initial evaluator is deliberately conservative:

- malformed or incomplete evidence is not review-ready;
- the evidence must be recent under the configured age limit;
- the PR head SHA must match the evidence target;
- every configured required check must be present, passed, and tied to that exact head SHA;
- skipped, failed, unknown, stale, or unverifiable required checks block readiness;
- at least the configured number of test results must be present and passed;
- missing accountable human identity blocks readiness;
- high/critical risk and sensitive-path changes are escalated for maintainer attention.

The policy is initially `report_only`: the evaluator reports readiness and blockers but does not alter PR state or grant/deny merge permissions. The evaluator's nonzero CLI exit indicates evidence failure to its caller; it does not itself enforce a GitHub merge gate.

## Provenance and audit semantics

Provenance events are ordered records, not a claim that the underlying data is immutable. Consumers should append events rather than rewrite history and retain source references (commit SHA, workflow run URL, PR URL) so claims can be independently checked.

Version 1 does not claim cryptographic attestation, tamper-proof storage, or a verified identity binding between an agent label and a provider account. Those require a separate threat model, key management, signing/verification implementation, and retention design before being represented as guarantees.

## Integration plan

- Reuse Vouch for contributor trust; do not treat a vouch tier as proof that a particular change is correct.
- Reuse PR Gate and existing repository-local CI rather than duplicate their execution.
- Consume agent identity/session metadata from provider adapters without making provider-specific fields mandatory. Optional `resource_usage` observations are checked against the provider pool and native unit in `config/agent-budget.yml`; no token-to-currency or cross-provider conversion is inferred.
- Link existing test and workflow logs as evidence; do not copy secrets or raw sensitive log content into the evidence artifact.
- Expose the evaluator through the authenticated, read-only `/api/fsa/governance/agent-evidence/:pr` route and `fsa governance evidence <pr-number>` CLI command. The route is feature-toggle-gated and report-only.
- Start with report-only summaries. Enforcement requires separate review of false-positive behavior, compatibility, security, and branch-protection configuration.

## PR governance integration (report-only)

The PR Gate looks for the newest issue comment among the latest 100 PR comments containing the marker `<!-- fsa-agent-evidence:v1 -->` followed by a fenced JSON evidence object. A comment is used as the transport so the evidence can target the exact PR head SHA without adding a commit that changes that SHA. The helper checks out governance code from the trusted base commit (never executes PR-supplied scripts), fetches comments through the read-only GitHub API, and writes a readiness summary. The comment author and timestamp are recorded as transport metadata, not trusted identity proof. Comments are mutable and are not an append-only audit store. Missing or invalid evidence is reported but does not change the existing PR Gate result in this initial rollout. Vouch and repository CI remain independent controls. The evidence must target the exact PR head SHA. The first GitHub adapter also checks each required validation's GitHub Actions run for that same SHA and verifies the matching job name and successful conclusion using the policy allowlist. Non-GitHub CI references remain blocked until an appropriate provider adapter is registered. Consumers must still verify any claimed human review independently.

The report helper is `scripts/report-agent-evidence-pr.py`. The same helper powers the FSA-API endpoint and the GitHub Actions summaries. It intentionally returns success to the PR Gate regardless of evidence outcome because the integration is informational only; the summary distinguishes passed, blocked, missing, and unavailable assessments. `agent-evidence-report.yml` repeats the assessment when `Validate Config` or `Agent Accountability Contract` completes, so evidence submitted before CI finishes is re-evaluated after those runs. This is not an approval or merge signal.

## CLI

Validate a JSON evidence artifact:

```bash
python3 scripts/validate-agent-evidence.py path/to/evidence.json
python3 scripts/validate-agent-evidence.py path/to/evidence.json --policy config/agent-accountability-policy.yml

# Query a PR through a running, authenticated FSA-API server:
fsa governance evidence 1032
```

Exit status 0 means the artifact meets the current policy's readiness criteria. A nonzero status means evidence is invalid or blocked. Neither result is a GitHub approval or merge authorization.

## Security and privacy

- Treat evidence as untrusted input.
- Never include access tokens, secrets, private keys, credentials, or unredacted sensitive logs. Resource usage records must contain only provider-native quantities and non-secret source references. Resource usage records must contain only provider-native quantities and non-secret source references.
- Verify external run references and commit identities at the integration boundary; schema validity alone is not source verification.
- Treat `human_review` as an untrusted claim until the referenced GitHub review is independently fetched and checked for reviewer identity, decision, PR, and commit SHA. Never accept a JSON field as proof of human approval.
- Keep policy changes subject to ordinary human review.
- Preserve existing Vouch, branch protection, CODEOWNERS, required checks, and human approval.
