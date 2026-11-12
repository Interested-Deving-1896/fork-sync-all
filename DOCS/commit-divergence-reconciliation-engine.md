# Commit Divergence & Reconciliation Engine

**Milestone:** read-only analysis core (v0.1.0). **Status:** advisory only; no provider adapter or branch writer is enabled.

## Purpose and boundaries

Provide one provider-neutral authority for understanding two histories, correlating likely equivalent changes, and producing evidence-backed recommendations. This complements, rather than replaces:

- Branch Topology, which discovers PR refs and stacked-PR relationships.
- Branch Manager / safe branch refresh, which owns separately authorized branch-update operations.
- PR Lifecycle Auditor, which evaluates review, checks, and lifecycle state.
- Code Archaeology and Origins, which provide historical and provenance evidence.

This must not become a second branch updater or merge controller.

## Direction and classification

Every comparison is explicitly base versus head. Counts follow GitHub compare semantics: ahead_by counts commits reachable from head but not base; behind_by counts commits reachable from base but not head. The report describes the relationship of head relative to base.

Classifications: identical, head_ahead, base_ahead, diverged, unrelated, unknown. Unknown is mandatory whenever exact refs, complete evidence, or provider comparison semantics cannot be verified.

## Current implementation

scripts/commit_divergence_engine.py accepts a normalized JSON snapshot and emits deterministic JSON or Markdown. It verifies exact requested SHAs, classifies ancestry, correlates unique patch IDs as candidates only, and emits advisory recommendations without executing operations.

Example input:

~~~json
{
  "provider": "github",
  "repository": "owner/repository",
  "base_ref": "main",
  "head_ref": "topic",
  "base_sha": "BASE_SHA",
  "head_sha": "HEAD_SHA",
  "comparison": {
    "base_sha": "BASE_SHA",
    "head_sha": "HEAD_SHA",
    "status": "diverged",
    "ahead_by": 5,
    "behind_by": 10,
    "merge_base_sha": "MERGE_BASE_SHA"
  },
  "commits": [],
  "incomplete_reasons": []
}
~~~

Run:

~~~sh
python3 scripts/commit_divergence_engine.py snapshot.json
python3 scripts/commit_divergence_engine.py snapshot.json --format markdown
python3 -m unittest discover -s tests -p 'test_commit_divergence_engine.py' -v
~~~

## Branch Topology adapter

The engine can consume a Branch Topology v1 report directly, without rediscovering pull requests or comparing branch names. The adapter is intentionally conservative: it requires schema version 1, GitHub provider identity, an explicitly read-only and complete topology report, exact base/head SHAs, a comparison explicitly marked consistent, and explicit base/head repository identities. The Branch Topology discovery adapter now builds GitHub compare requests using the base repository plus the fork owner's qualified head ref (`owner:branch`). It accepts the result only when GitHub returns both exact requested SHAs; moved refs, missing commits, or incomplete responses remain unknown. The fork repository identity is retained in the snapshot. This is a read-only compare operation and does not alter either repository.

Run the batch adapter:

~~~sh
python3 scripts/commit_divergence_engine.py branch-topology.json --branch-topology
python3 scripts/commit_divergence_engine.py branch-topology.json --branch-topology --format markdown
~~~

The JSON result contains one independent divergence report per PR plus a batch completeness status. Any incomplete discovery, stale/mismatched comparison, unsupported schema/provider, unknown relationship, missing SHA, or fork-repository mismatch prevents the batch from being reported complete. The adapter is read-only and cannot update refs, PRs, or workflows.

## Recommendation semantics

| Relationship | Advisory recommendation | Automatic action |
|---|---|---|
| identical | no-op | none |
| head_ahead | fast-forward candidate | none |
| base_ahead | head-update candidate | none |
| diverged | manual reconciliation | prohibited |
| unrelated | manual review | prohibited |
| unknown / incomplete | manual review | prohibited |

Patch-ID matches can be affected by whitespace, metadata, context, merge commits, and patch drift. They do not prove authorship, intent, licensing, provenance, or semantic equivalence. They must never silently discard or replace commits.

## Future provider-neutral architecture

1. Discovery adapters: GitHub, GitLab, local Git; capture immutable exact refs/SHAs, repository identity, timestamps, and pagination completeness.
2. Normalization: provider-neutral snapshots retaining unknown and incomplete states.
3. Ancestry analysis: merge base, ahead/behind counts, unrelated histories, and ref-movement detection.
4. Commit correlation: patch-id and explicit cherry-pick/rebase/squash evidence with confidence and ambiguity.
5. Dependency graph: consume Branch Topology evidence while keeping PR ancestry distinct from repository-origin/provenance graphs.
6. Resolution planner: recommend fast-forward, merge-update, rebase, cherry-pick, recreate, superseded, or human review; never execute from graph order alone.
7. Execution boundary: a separate future adapter gated by explicit operation-level authorization, exact-SHA compare-and-swap, isolated staging refs, non-force updates by default, audit logs, idempotency, and recovery.
8. Verification: re-read refs after operation and validate expected history/diff and exact-head required checks.

## Hard safety invariants

- Read-only is the only supported mode in this milestone.
- No checkout, reset, rebase, cherry-pick, merge, commit, push, force-push, ref update, branch deletion, PR state mutation, workflow dispatch, or mirror write.
- Never infer safe execution from a green check attached to an older SHA.
- Never execute when a ref moved after observation, evidence is incomplete, ancestry is ambiguous, or a dependency cycle exists.
- Never rewrite or discard divergent history automatically.
- Keep downstream mirror writes deferred until the source-repository audit/resolution gate is explicitly complete.

## Integration plan

Consume Branch Topology snapshots rather than duplicating PR discovery. Use Branch Manager's safe updater only after separate review; do not add a second refresh workflow. Treat lifecycle checks as evidence, not authorization. Reuse Code Archaeology / Origins evidence for context while keeping provenance decisions human-reviewed. Provider adapters and any execution mode require separate milestones and exact-head validation.
