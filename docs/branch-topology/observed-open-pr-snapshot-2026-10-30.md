# Open PR branch-topology snapshot — 2026-10-30

> Historical read-only observation. This report is not a repair plan and does not authorize or perform branch updates, rebases, merges, workflow dispatches, or mirror writes. Refresh before acting on any finding.

## Method

- Source: GitHub REST `GET /repos/Interested-Deving-1896/fork-sync-all/pulls?state=open&per_page=100`.
- Retrieved both pages: 100 + 93 records; page 2 contained fewer than 100, so the listing was complete at observation time.
- Compared each PR's observed `base.ref` to open PR `head.ref` values.
- For matching branch names, compared the exact observed `base.sha` to the matching PR's `head.sha`.
- This detects *observed branch-name stack relationships* and stale base snapshots. It does not prove commit ancestry, mergeability, content integration, CI health, or whether a PR branch was deleted/recreated between observations.
- No external head/base repositories were present in this snapshot. This does not constitute cross-fork coverage.
- The topological listing is not a repair sequence; disconnected PRs are included for deterministic inventory only.

## Inventory

| Measure | Count |
|---|---:|
| Open PRs | 193 |
| Draft PRs | 184 |
| Non-draft PRs | 9 |
| PRs targeting `main` | 82 |
| Observed stack edges (base branch matches another open PR head branch) | 111 |
| Stack edges with mismatched base/head SHA | 8 |
| Non-`main` bases without a matching open PR head branch | 0 |
| External fork PRs | 0 |
| Cycle/downstream nodes in the inferred graph | 0 |

## Stale base SHA findings

These are exact ref observations at snapshot time. A mismatch means the child PR's base SHA does not equal the current head SHA recorded for the parent PR. It does not, by itself, prove the child is behind or diverged; compare-commit ancestry is required before selecting an update action.

| Parent PR | Child PR | Base branch | Parent head SHA | Child observed base SHA |
|---:|---:|---|---|---|
| #898 | #899 | `feat/local-project-template-bundles` | `3854012ba3aa620da52553fab65810675c027a60` | `1c01dcad60cfc3968b3332493ad58aa4c7e30669` |
| #897 | #898 | `feat/project-template-registry-resolver` | `13b6e7cc78ad28aa19c3a60059d226db69a586ce` | `183e3b56f136260921901e8638dc7402db5113c5` |
| #885 | #886 | `docs/blincus-workspace-integration-audit` | `784460368918eeae3a39499f8680baf18d88c18c` | `23c84e19b5eb64b2c07e4799f1688db75f1ff445` |
| #724 | #772 | `fix/gitlab-upstream-mirror-pagination-20261020` | `bd7dacd4a113cceee4a6b94a552846b2a0c47677` | `597347a98817c773477a8892d7f0f7c1eb751447` |
| #764 | #765 | `test/git-platform-sync-mocked-lifecycle` | `fc4e4604ba1dffcb323d4fb9a28d69a2006acfec` | `557789619c4385bed4ee1c3e0995e8f547f38e32` |
| #749 | #751 | `test/gitlab-mirror-discovery-fixtures-724` | `7bc1b6130d65dce153c68bdbf8dca3e58fee222c` | `ae6c04bc23636c4da474cac95cb4abc871c0d861` |
| #724 | #749 | `fix/gitlab-upstream-mirror-pagination-20261020` | `bd7dacd4a113cceee4a6b94a552846b2a0c47677` | `597347a98817c773477a8892d7f0f7c1eb751447` |
| #724 | #746 | `fix/gitlab-upstream-mirror-pagination-20261020` | `bd7dacd4a113cceee4a6b94a552846b2a0c47677` | `597347a98817c773477a8892d7f0f7c1eb751447` |

## Project Creation Engine stack

Observed branch chain:

`#882 → #895 → #896 → #897 → #898 → #899 → #900 → #901 → #904`

The base SHA mismatches are specifically:
- #897 → #898
- #898 → #899

All other adjacent edges in this chain matched their recorded parent head SHA at observation time. #903 is a separate PR targeting `main`.

## Recommended read-only follow-up

1. Run compare-commit checks for the eight mismatched edges and record ahead/behind/diverged/unknown with merge-base SHA.
2. Re-fetch each PR's base/head refs immediately before any future repair proposal; branch names alone are not stable identities.
3. Add explicit fixtures for branch deletion/recreation, changing refs between discovery and comparison, cross-fork PRs, and comparison API failures.
4. Integrate this normalized evidence with the existing PR Lifecycle Auditor rather than introducing a competing lifecycle status store.
5. Keep repair execution separately gated with expected-head compare-and-swap, no force-push by default, audit records, and recovery handling.

## Limitations

- This is a point-in-time inventory, not a live dashboard.
- No CI evidence is included in the graph metrics.
- No compare-commit ancestry checks were performed for the eight mismatches in this snapshot.
- No branch mutations or PR state changes were made.
