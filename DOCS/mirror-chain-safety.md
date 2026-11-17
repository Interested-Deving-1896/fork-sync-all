# Staged GitHub mirror safety

## Source → OSP

The source-to-OSP leg is temporarily read-only while its replacement ref planner
is developed. The workflow pins `DRY_RUN=true` and `FORCE=false`; the script
also defaults to dry-run and exits before network access if live mode is
requested. This prevents the legacy `git push --mirror` path from overwriting
or deleting destination refs. Repository inventory and eligibility inspection
remain available.

## OSP → OOC

The OSP-to-OOC leg uses `scripts/mirror_chain_push.py`.

- The planner defaults to dry-run; target-only branches and tags are retained.
- It enumerates every source branch from the OSP `origin` remote.
- Branches are created when absent or advanced only when the target is an
  ancestor of the OSP source commit. A target-ahead branch is preserved;
  divergence blocks the complete plan.
- New tags may be created; existing tags must match exactly. A conflicting tag
  blocks the complete plan.
- Every proposed ref is checked with `git push --dry-run` before the first
  write.
- No force push, ref deletion, pruning, or implicit overwrite is supported.
- The workflow keeps scheduled runs read-only. A write path additionally
  requires a manual dispatch, `dry_run=false`, `enable_writes=true`,
  `approve_write=true`, and the protected `MIRROR_TOKEN` secret.

## Deployment boundary

Both production mirror legs remain read-only during this development phase.
No mirror workflow is dispatched by this work. A later canary still requires
explicit repo ownership/protection review, target branch protection inspection,
a disposable allowlisted repository, parity/provenance evidence, and a
rollback plan. This planner does not manage repository creation, branch
protection, human-owned README sections, or rollback of already-pushed refs.

NativeLink remains an optional REAPI build/cache adapter; it is not Git
transport, mirror authorization, or a prerequisite for mirror-chain operation.
