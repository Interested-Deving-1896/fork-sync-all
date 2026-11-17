# Staged GitHub mirror updates (OSP → OOC)

The OSP-to-OOC leg is intentionally non-destructive.

- The planner defaults to dry-run; target-only branches and tags are retained.
- Branches are created when absent or advanced only when the target is an ancestor
  of the OSP source commit. Divergence blocks the complete plan.
- Existing tags must match exactly. A conflicting tag blocks the complete plan.
- Every proposed ref is checked with `git push --dry-run` before any write.
- No force push, ref deletion, pruning, or implicit overwrite is supported.
- Writes require `--write`, a manual `workflow_dispatch`, and both
  `MIRROR_WRITE_ENABLED=true` and `MIRROR_WRITE_APPROVED=true`, plus the
  protected `MIRROR_TOKEN` secret.

The workflow keeps scheduled runs in dry-run mode. This implementation is a
development safeguard, not authorization to perform a live mirror deployment.
A future canary still needs explicit repo ownership/protection review, target
branch protection inspection, and staged approval. The planner does not manage
repository creation, branch protection, human-owned README sections, or rollback
of already-pushed refs.
