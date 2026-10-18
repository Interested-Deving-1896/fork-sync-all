# Update pull request branches

Fork-Sync-All's **Update PR Branches** workflow keeps open pull requests current with their base branch. It supports both GitHub branch-update methods through the pull-request update-branch API.

## Methods

- `merge` (default): merge the base branch into the pull request branch. This preserves existing commits and does not rewrite the PR branch history.
- `rebase`: replay the PR branch commits on top of the base branch. This can rewrite branch history, so use it only where branch policy and contributor expectations permit it.

The workflow does not merge pull requests. It only updates branches that GitHub reports as behind; conflicting, blocked, draft (by default), and unknown-state PRs are skipped or reported.

## Configuration and triggers

- **Automatic runs:** the existing workflow triggers after the Validate Config workflow and on its scheduled safety-net cadence.
- **Manual run:** open Actions → Update PR Branches → Run workflow. Choose `merge` or `rebase`, optionally filter by base branch or PR numbers, and use dry-run to preview.
- **Scheduled default:** set repository variable `BRANCH_UPDATE_METHOD` to `merge` or `rebase`. If unset or invalid, the script uses `merge` as its safe default / validation guard.

A manually selected method takes precedence over the repository variable. The script rejects unsupported methods before making API calls.

## Safety

- Draft PRs are skipped by default.
- Dry-run reports intended changes without updating branches or posting comments.
- The update request includes the PR head SHA observed during inspection, so GitHub can reject a stale update if the branch changes concurrently.
- Conflict comments give instructions matching the selected method; rebasing instructions use `--force-with-lease`, while merge instructions use a normal push.
- The workflow respects the repository's existing quota guard and Fork-Sync-All managed-mode guard.
- This automation never approves or merges a PR and never force-pushes a branch itself; GitHub performs the selected update operation.
