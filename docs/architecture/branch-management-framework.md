# Branch Management Framework — Architecture Proposal

## Status

Proposal for review. This document defines the intended contract before implementing mutating branch operations. It does not authorize merges, branch deletion, force-pushes, or changes to repository protection settings.

## 1. Goals

Build a provider-aware but Git-platform-neutral branch lifecycle framework that can inventory, classify, plan, validate, and (when explicitly authorized) apply branch operations across a repository.

The default topology is a hub-and-spoke model:

- `main` is the authoritative integration branch.
- New independent work branches are created from `main` by default.
- Approved branch changes ultimately flow back to `main` through a pull/merge request or another explicitly configured integration path.
- Branches may be refreshed from `main`, or from a declared parent branch when they are part of a stack.
- Bidirectional synchronization is an opt-in policy, not a global default. Git branches are histories, not folders; copying changes both ways can create conflicts or unintended reversions.

## 2. Required distinctions

The framework must not conflate these separate operations:

1. **Create** — create a branch at a selected base commit.
2. **Refresh** — bring a working branch up to date with its declared source, using merge or rebase according to policy.
3. **Integrate** — propose or apply a branch's changes into its target branch.
4. **Reconcile** — inspect divergence and produce a plan for resolving it; never guess how to resolve conflicts.
5. **Promote** — move a validated change through configured integration stages.
6. **Retire** — mark a branch inactive or archived.
7. **Prune** — delete an eligible branch only after checks and explicit policy authorization.
8. **Recover** — preserve enough metadata and commit references to explain or recover from an interrupted operation.

A branch's source, target, parent, and allowed operations must be explicit metadata. The default source and destination can both be `main`, but a branch stack may declare another working branch as its immediate parent while retaining `main` as the eventual integration destination.

## 3. Proposed branch policy model

Each managed branch should resolve to a policy with fields equivalent to:

- `name_pattern` / `role`: feature, fix, maintenance, release, integration, generated, or protected.
- `source_ref`: default `main`; explicit parent allowed for a declared stack.
- `target_ref`: default `main`.
- `refresh_strategy`: report-only, merge, or rebase.
- `integration_strategy`: pull request by default; direct merge only if separately permitted.
- `allowed_operations`: explicit allow-list.
- `required_checks`: required CI and review evidence.
- `delete_policy`: never, manual approval, or eligible-after-verified-integration.
- `owner` / `ownership_mode`: human-owned, automation-owned, or shared.
- `exceptions`: narrow, auditable overrides with an expiry or reason.

Protected branches, including `main`, must never be treated as disposable working branches. Human-owned branches and README sections are preserved unless their owners explicitly authorize changes.

## 4. Direction and flow modes

Support the following modes, selected per branch or operation:

- **Unidirectional to main:** branch -> PR -> `main`; the default integration flow.
- **Unidirectional from main:** `main` -> working branch; the default refresh flow.
- **Stacked:** `main` -> parent -> child, with each child targeting its declared parent until the stack is ready for integration.
- **Bidirectional reconcile:** inspect both histories, report divergence, and propose a merge/rebase plan. Applying the plan requires explicit authorization and conflict-free validation or human conflict resolution.
- **Promotion pipeline:** branch -> integration branch -> `main`, only when configured.
- **Read-only audit:** enumerate branches, relationships, divergence, stale status, open PRs, CI evidence, and possible cleanup candidates without modifying anything.

“Bidirectional” means both directions are supported as separately governed operations; it does not mean automatically overwriting one side with the other.

## 5. Lifecycle state machine

Track lifecycle state separately from GitHub PR state:

`discovered -> classified -> active -> ready_for_review -> integration_eligible -> integrated -> retirement_eligible -> retired`

Additional states: `blocked`, `conflicted`, `stale`, `unknown`, and `protected`.

Transitions require evidence. For example, a green check run alone does not prove a PR is safe to merge, and a closed PR does not prove that its branch is safe to delete. The framework must distinguish merged, closed-unmerged, abandoned, superseded, and unknown outcomes.

## 6. Safety invariants

- Default mode is dry-run / plan-only.
- No branch mutation occurs unless the selected operation and policy explicitly authorize it.
- Never force-push, reset, delete, or rewrite a shared branch by default.
- Never merge `main` into another branch or another branch into `main` merely because the branch exists.
- Never infer successful CI from missing, malformed, pending, stale, or incomplete check evidence.
- Bind merge decisions to the exact head SHA whose checks were verified; refuse if the head changes.
- For stacked PRs, preserve dependency order and validate the complete stack; do not integrate a child independently of required parents.
- Branch deletion requires positive evidence of integration or an explicitly approved retirement exception, no open dependent PRs, and a final fresh check.
- API, permission, inventory, or pagination failures must fail closed and leave branches untouched.
- Do not alter repository settings, secrets, rulesets, or branch protections as a side effect.
- Keep an audit log of the proposed action, policy, source/target SHAs, evidence, outcome, and actor.
- Keep downstream mirror writes and human-owned README areas outside this framework unless separately authorized.

## 7. Execution architecture

Recommended layers:

1. **Provider adapter** — GitHub/GitLab/API-specific reads and explicitly enabled writes.
2. **Inventory** — branches, refs, PR/MR relationships, commits, check evidence, protection metadata when accessible.
3. **Relationship graph** — source/parent/target edges and stacked PR dependencies.
4. **Policy resolver** — combines global defaults, branch role, repository policy, and narrowly scoped overrides.
5. **Planner** — emits a deterministic action plan without applying it.
6. **Validator** — checks permissions, fresh SHAs, required evidence, graph order, conflicts, and deletion eligibility.
7. **Executor** — applies only approved operations; one operation at a time with concurrency control and idempotency.
8. **Auditor/dashboard** — reports state, drift, blockers, candidate actions, and action history.

The provider-neutral core should operate on a common model; provider adapters must document capabilities and limitations rather than pretending all platforms have identical semantics.

## 8. Suggested CLI/API shape

Initial read-only commands:

- `branch-manager inventory`
- `branch-manager graph`
- `branch-manager plan --target main`
- `branch-manager status`
- `branch-manager explain <branch>`

Later, guarded mutation commands can include:

- `branch-manager branch create <name> --from main`
- `branch-manager branch refresh <name> --strategy merge|rebase`
- `branch-manager integrate <branch> --target main`
- `branch-manager branch retire <name>`
- `branch-manager prune --plan <plan-id>`

Mutating commands should require an explicit apply/approval mechanism and should show the exact source and target SHAs before proceeding. A CLI flag alone must not bypass repository policy or platform protections.

## 9. Phased implementation

**Phase 1 — read-only inventory and graph.** Discover branches and PR dependencies; classify protected branches; report source/target, divergence, stale status, and missing evidence. No writes.

**Phase 2 — deterministic planner.** Generate JSON and human-readable plans for create/refresh/integrate/retire candidates. Add fixtures for normal branches, stacked PRs, divergent histories, missing pages, API errors, and stale SHAs.

**Phase 3 — safe branch creation and refresh.** Permit creating new branches from the configured source. Refresh only on explicit request and with merge/rebase policy selected; do not rewrite shared branches by default.

**Phase 4 — PR-driven integration.** Open or update PRs and evaluate required evidence. Keep merge execution disabled unless separately authorized. If enabled in a future approved phase, bind the operation to the verified head SHA and respect all protection rules.

**Phase 5 — retirement and pruning.** Start with candidate reports. Add deletion only after integration status, dependencies, ownership, permissions, and fresh inventory are verified and the specific policy authorizes it.

**Phase 6 — multi-provider and dashboard integration.** Add GitLab and other adapters, event-driven reconciliation, sub-dashboards, and audit trails without weakening the provider-neutral safety contract.

## 10. Acceptance criteria

- Default execution is read-only and produces a deterministic plan.
- `main` is the default source for new independent branches and the default final integration target.
- Stacked branches retain explicit parent relationships and integrate in dependency order.
- No merge, rebase, force-push, or deletion happens on incomplete or ambiguous evidence.
- Tests prove stale-SHA refusal, fail-closed API behavior, dry-run non-mutation, protection of `main`, and prevention of pruning open/dependent/unmerged branches.
- Every proposed mutation is explainable and auditable.
- Provider-specific behavior is covered by adapter contract tests.
- Existing repository guardrails and human ownership remain authoritative.

## 11. Decisions to settle before mutation support

The proposal can proceed with safe defaults, but these should be made configurable:

1. Whether the default refresh strategy is merge or rebase (recommendation: report-only initially; merge for shared branches, rebase only for branches explicitly marked rewrite-safe).
2. Which branch roles may be auto-created or auto-refreshed.
3. Whether integration always requires a PR (recommendation: yes).
4. Which checks and review approvals are required.
5. Whether pruning is ever automatic (recommendation: report candidates first; require explicit approval for deletion).
6. Which Git providers are in scope for the first implementation.

## Summary

Treat `main` as the default source and final integration destination, while representing each working branch as a governed node in a directed relationship graph. Support multiple synchronization directions, but make every operation policy-driven, observable, reversible where possible, and fail-closed by default.
