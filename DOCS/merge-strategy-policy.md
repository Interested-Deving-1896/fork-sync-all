# Repository Merge Strategy Policy

This policy standardizes merge-method selection across Fork-Sync-All and its related repositories. It is guidance for maintainers; it does not authorize automatic merging or override branch protection, required checks, reviews, or explicit maintainer approval.

## Default: squash and merge

Use **Squash and merge** for self-contained PRs representing one logical change: routine fixes, small features, refactors, documentation, and dependency updates.

Benefits: concise history, one logical commit per PR, straightforward revert, and less WIP clutter. Ensure the PR title/commit message accurately describes the complete change and meaningful authorship or release-note details are not lost.

## Use a merge commit when history or topology matters

Choose **Create a merge commit** when:
- Several commits are meaningful and independently valuable.
- The PR is stacked/dependent and preserving its commit graph aids auditability.
- It is a coordinated integration, synchronization, or migration where provenance matters.
- A deliberate branch structure needs to be retained.

Do not preserve noisy WIP commits just for their own sake; clean them up first when appropriate.

## Use rebase and merge for clean linear history

Choose **Rebase and merge** only when the PR is independent, commits are focused and ordered, linear history is desired, and rewriting commit SHAs will not break references, signatures, or downstream consumers.

Avoid this for dependent stacks or SHA-sensitive automation.

## Stacked and dependent PRs

1. Verify each PR's base and head branch.
2. Proceed in dependency order only after prerequisites are approved and green.
3. Prefer merge commits when retaining the dependency graph is valuable.
4. Never rebase, retarget, or merge a stack based on inferred ordering; verify topology first.
5. Re-check affected checks after branch updates or history rewrites.

## Required safeguards

A merge method never substitutes for required reviews/CODEOWNERS, CI and branch protection, conflict resolution, current-base verification, or explicit merge authorization.

No automation should merge merely because a PR is green unless a separately reviewed and explicitly enabled auto-merge policy exists.

## Quick decision guide

| PR type | Preferred method |
|---|---|
| Independent, one logical change | Squash and merge |
| Independent, clean multi-commit series; linear history desired | Rebase and merge |
| Stacked/dependent PR or topology/provenance-sensitive integration | Merge commit |
| Noisy WIP commits | Clean up first; usually squash |
| Dependency/topology unclear | Pause and inspect; do not merge |

## Scope and adoption

This is the baseline policy for Fork-Sync-All. Related repositories may adopt it or add stricter local rules. Document repository-specific exceptions in their contributing guidance.

This policy is guidance—not permission to merge. Maintainer authorization remains separate and explicit.
