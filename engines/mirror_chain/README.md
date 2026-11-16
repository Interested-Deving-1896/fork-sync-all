# Mirror-chain Provisioner Engine

The mirror-chain provisioner is a desired-state engine for repository topology.
It is intended to support arbitrary provider/org graphs rather than hard-code
the Interested-Deving-1896 → OSP → OOC example.

## Safety model

- A repository coordinate (provider/owner/name) is not an identity. Adapters
  resolve it to an immutable provider repository ID.
- Existing destinations are never overwritten, renamed, deleted, or converted.
- Native forks require verified fork ancestry. Clone mirrors are a distinct
  strategy and must be implemented by an adapter with explicit write policy.
- A dry-run plan is the default. Apply re-resolves destinations immediately
  before writes and verifies every created repository.
- Redirects and renamed repositories must be resolved by immutable ID and
  reported as identity conflicts when the resolved repository is not the
  desired destination. A redirect is never proof that the destination is safe.

## Current incident: profile repository name collision

The previous onboarding attempt targeted
`OpenOS-Project-OSP/Interested-Deving-1896` and
`OpenOS-Project-Ecosystem-OOC/Interested-Deving-1896`. GitHub redirects
those paths to repository IDs `1386544610` and `1386544723`, which currently
resolve to the independent organization profile repositories
`OpenOS-Project-OSP/OpenOS-Project-OSP` and
`OpenOS-Project-Ecosystem-OOC/OpenOS-Project-Ecosystem-OOC`.
Both report `fork=false`. The existing provisioner correctly refuses them.

These profile repositories are not mirror-chain nodes and must remain
independent. The profile publisher/delegation contract remains separate from
the canonical account repository's mirror topology. Do not try to recreate
the old names by renaming, deleting, or converting either profile repository.

## Implementation status

This change introduces the provider-neutral graph model, adapter contract,
dry-run planner, and fail-closed apply orchestration in
`engines/mirror_chain/__init__.py`. The existing GitHub script remains the
operational entry point until a GitHub adapter is implemented and contract
tests prove parity. It is intentionally not switched over by this foundational
change.

## Next integration stages

1. Implement GitHub adapter with immutable-ID and redirect resolution.
2. Add provider contract tests and fake-provider integration tests.
3. Migrate `scripts/add_mirror_repo.py` to the engine without changing its
   current safety behavior.
4. Reconcile canonical, OSP, and OOC topology from declarative configuration.
5. Connect onboarding, project creation, lifecycle audit, and maintenance
   workflows through a single engine API.
6. Only then enable provisioning for the profile repository and verify it
   end-to-end. Profile README repositories remain protected from generic
   template writes.
