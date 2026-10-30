# Read-only Branch Topology Engine

## Safety boundary
This milestone only observes GitHub and emits advisory reports. It must not update refs, rebase or merge branches, change PR state, dispatch workflows, post comments, change permissions, or write downstream mirrors.

## Discovery and analysis
- Enumerate every open PR including drafts and PRs based on another PR branch.
- Normalize provider observations into a provider-neutral snapshot: provider identifier, repository/default branch, observation timestamp, PR URL/number, draft/state, base/head repository, branch refs, exact SHAs, and comparison status plus ahead/behind counts.
- Keep GitHub REST discovery as the first adapter; analysis consumes the normalized snapshot and does not depend on GitHub response objects.
- Infer a dependency only if a PR base repository/ref exactly matches one unique open PR head repository/ref. Record the evidence and confidence; distinguish inferred edges from provider facts.
- Flag stale base SHAs, ambiguous parents, cycles, missing metadata, comparison failures, and pagination/API errors.
- Fail closed: incomplete or ambiguous evidence must not produce a repair order.
- Emit JSON and Markdown reports. A topological listing is not a repair plan: it orders all observed PR nodes (including disconnected PRs) deterministically and must not be interpreted as a recommendation to update, rebase, or merge. The report contains no executable repair plan in this first milestone.

## Test matrix
Linear stack; stale base; diverged comparison; unrelated PRs; ambiguous parent; cycle; missing comparison; incomplete discovery; deterministic output; repository-metadata failure; pagination failure; comparison-endpoint failure; deleted/missing refs; unknown ref existence; cross-repository/fork comparisons; and comparison responses whose returned SHAs differ from the requested snapshot. Provider failures are retained in the normalized snapshot and force an incomplete/unknown result rather than being treated as safe.

## Integration
Feed the report into the existing PR Lifecycle Auditor/dashboard. Keep this PR-ancestry graph separate from repository-origin dependency graphs. Do not add a second lifecycle status authority.

## Next milestone gates
1. Run unit tests and static checks in CI.
2. Verify report against current open PR stack and record exact head SHA and evidence.
3. Review security, rate-limit behavior, API pagination, fork/cross-repository branches, and missing/deleted refs. The current GitHub adapter intentionally marks cross-repository comparisons incomplete; it does not yet perform a fork-aware comparison.
4. Add provider response-shape fixtures and implement a provider-specific ref-existence probe if reliable deletion detection is required. The current normalized model treats unobserved ref existence as unknown, never as present.\n5. Only later, consider a separately authorized updater with expected-head compare-and-swap and explicit side-effect gates.
