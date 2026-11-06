# Provider-Neutral Merge-Strategy Classifier — Specification

**Status:** Proposed; read-only
**Related tracking issue:** #908
**Policy:** `DOCS/merge-strategy-policy.md`

## Purpose

Analyze pull requests and merge requests across supported Git providers and produce a deterministic, explainable recommendation: squash, merge commit, rebase, or hold. The classifier prepares a plan; it does not merge, rebase, retarget, or rewrite branches.

## Provider-neutral input contract

Each adapter normalizes provider data into provider/repository identity; change request ID, URL, title, source and target branches; commit count and metadata; changed paths and diff scope; related change requests and explicit dependency evidence; mergeability/conflict state; CI/check states; review/approval and branch-protection facts where accessible; observation timestamp; pagination completeness; and API error/permission status.

Missing or incomplete fields are **unknown**, not guessed.

## Classification outcomes

### squash
Independent change request representing one coherent logical change. Noisy/fixup commits may be collapsed after human review.

### merge_commit
Meaningful multi-commit history, integration/provenance requirement, or verified stacked topology where retaining ancestry aids auditability.

### rebase
Independent, clean commit series when rewriting commit IDs is safe and preserving topology is unnecessary.

### hold
Failing required check, unresolved conflict, missing approval, ambiguous/incomplete dependency graph, incomplete pagination, provider error, or policy conflict. Hold takes precedence over any execution readiness.

Every result includes strategy; readiness (`ready_for_review`, `blocked`, `insufficient_evidence`); rationale/evidence; confidence and factors; blockers/unknowns; dependencies/order if verified; policy and classifier versions.

## Dependency and topology rules

1. Use explicit base/head facts, commit ancestry, and provider relationship metadata.
2. Build a directed graph only from evidence-backed dependencies.
3. Detect cycles and inconsistent base/head data; hold affected nodes.
4. Never infer stack order from PR number, date, title, or branch-name similarity alone.
5. Incomplete graph discovery/pagination marks the plan incomplete and prohibits ordering/execution recommendations.

## Plan generation

Emit Markdown with provider/repository, observation timestamp, adapter/classifier/policy versions; completeness/limitations; summary counts; per-PR/MR classification, readiness, rationale, confidence and blockers; verified dependency graph/order; human review checklist; and source links.

Artifacts are versioned or content-addressed. Do not overwrite history silently.

## Tracking and reconciliation

- One canonical issue per repository and configured scope.
- Stable key: provider + repository ID + scope + tracker type; verify marker/metadata before updating.
- Repeated runs update the canonical issue and publish a new plan version only when meaningful inputs change.
- Include last-observed timestamp and compact delta.
- Check closed/archived issue behavior by policy; do not duplicate blindly.
- If artifact/issue write fails, retain analysis and report tracker failure.
- Comments only for meaningful deltas, not every polling cycle.

## Safety and execution boundary

Phase 1 is read-only. Any later executor is separate and disabled by default, requires explicit authorization, revalidates checks/dependencies immediately before action, and respects provider protections. Green checks alone never imply permission to merge.

## Test matrix

- Independent one-commit PR → squash
- Clean independent multi-commit → rebase if policy permits
- Meaningful integration history → merge commit
- Verified stack → dependency-aware order, topology-preserving option
- WIP/fixup → squash recommendation with caveat
- Failed/pending required check → hold
- Conflict or missing review → hold
- Missing base/head or incomplete pagination → hold / insufficient evidence
- API 401/403/429/5xx → fail closed
- Cyclic/contradictory dependency evidence → hold
- Identical repeated run → idempotent tracking/artifact behavior

## Delivery phases

1. Schema, pure classifier, deterministic fixtures.
2. GitHub read adapter and completeness/error handling.
3. Markdown renderer and canonical issue reconciliation.
4. GitLab adapter in coordination with `gitlab-enhanced`.
5. Dashboard, notifications, telemetry.
6. Separately designed opt-in execution adapter (not part of classifier).
