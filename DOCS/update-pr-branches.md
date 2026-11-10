# Update pull request branches

Fork-Sync-All's **Update PR Branches** workflow keeps open pull requests current with their base branch. It supports both GitHub branch-update methods: the REST update-branch endpoint for merge updates and GitHub CLI for rebase updates.

## Methods

- `merge` (default): merge the base branch into the pull request branch. This preserves existing commits and does not rewrite the PR branch history.
- `rebase`: replay the PR branch commits on top of the base branch. This can rewrite branch history, so use it only where branch policy and contributor expectations permit it.

The workflow does not merge pull requests. It only updates branches that GitHub reports as behind; conflicting, blocked, draft (by default), and unknown-state PRs are skipped or reported.

## Configuration and triggers

- **Automatic runs:** the workflow runs after a successful Validate Config workflow on the default branch and on its scheduled safety-net cadence.
- **Manual run:** open Actions → Update PR Branches → Run workflow. Choose `merge` or `rebase`, optionally filter by base branch or PR numbers, and use dry-run to preview.
- The workflow always targets its own `github.repository`; there is no caller-supplied repository override. Write-capable jobs are guarded to the default branch.
- Concurrent triggers are serialized (`cancel-in-progress: false`) so a later run cannot cancel an active scan midway through its PR set.
- **Scheduled default:** set repository variable `BRANCH_UPDATE_METHOD` to `merge` or `rebase`. If unset, the workflow defaults to `merge`; an invalid value is rejected before any update.

A manually selected method takes precedence over the repository variable. The script rejects unsupported methods before making API calls.

## Safety

- Draft PRs are skipped by default.
- Dry-run reports intended changes without updating branches or posting comments.
- Merge update requests include the PR head SHA observed during inspection, so GitHub can reject a stale update if the branch changes concurrently. Rebase uses the supported `gh pr update-branch --rebase` command.
- Conflict comments give instructions matching the selected method; rebasing instructions use `--force-with-lease`, while merge instructions use a normal push.
- The workflow respects the repository's existing quota guard and Fork-Sync-All managed-mode guard.
- PR discovery is fail-closed: any listing-page API error, malformed response/entry, or duplicate PR number aborts the entire pass before candidate processing. It never continues with a partial page set.
- Before acting on a listed PR, the workflow re-fetches it and requires the state, head ref, exact head SHA, base ref, and draft state to match the discovery snapshot. A changed or uncertain candidate is skipped.
- Draft PRs remain skipped by default. Only a manual dispatch can explicitly set `skip_drafts: false`.
- This automation never approves or merges a PR. For rebase, it delegates the branch rewrite to GitHub CLI rather than performing a local force-push; use that mode only when branch policy and contributor expectations permit it.
