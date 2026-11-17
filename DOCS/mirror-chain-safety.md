# Staged GitHub mirror safety

## Development hold

All Git-ref mirror writers remain paused during this development phase. The
legacy workflows for bulk OSP/OOC mirroring, mirror setup/provisioning, GitLab
sidecar mirroring, generic mirror dispatch, consumer mirroring, and the
reverse-direction BDFS workflow are reduced to manual safety-hold notices.
Their scheduled, push, and workflow-run triggers are removed. See issue #1038
for the remaining writer inventory and classification.

## Source → OSP

The source-to-OSP leg is read-only. The workflow pins `DRY_RUN=true` and
`FORCE=false`; the script also defaults to dry-run and exits before network
access if live mode is requested. This prevents the legacy `git push --mirror`
path from overwriting or deleting destination refs. Repository inventory and
eligibility inspection remain available.

## OSP → OOC

The OSP-to-OOC `lkm` leg uses `scripts/mirror_chain_push.py` as a read-only
planner. It has no push command, token handling, credential access, or write
mode.

- It enumerates every source branch from the OSP `origin` remote.
- Branches are classified as create, unchanged, fast-forward, target-ahead
  (preserve), or blocked divergence.
- New tags may be created in a future approved implementation; existing tags
  must match exactly. Conflicting tags block the plan.
- Target-only branches and tags are retained.
- Local preflight namespaces are pruned to prevent stale local refs; remote
  refs are never pruned or deleted.

## Deployment boundary

No mirror workflow is dispatched and no mirror writes are performed as part of
this development work. A later canary requires explicit repo ownership and
branch-protection review, a disposable allowlisted repository, parity and
provenance evidence, CI/admission gates, and a rollback plan. Human-owned README
sections and protected/delegated repositories must remain untouched.

NativeLink remains an optional REAPI build/cache adapter; it is not Git
transport, mirror authorization, or a prerequisite for mirror-chain operation.
