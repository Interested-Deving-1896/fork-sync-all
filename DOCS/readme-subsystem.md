# Forge-neutral README subsystem

The README subsystem separates reusable automation from profile identity and
uses forge-neutral terms throughout its contract:

- a **namespace** may be a GitHub organization or user, a GitLab group or
  subgroup, a Gitea/Forgejo organization, or another forge's equivalent;
- a **project** is the hosted Git repository;
- a **profile surface** is whichever README location a forge chooses to expose.

The machine-readable contract is `config/readme-subsystem.json`. The local
engine is `scripts/readme-subsystem.py`, and `readme-subsystem/action.yml`
provides the GitHub Actions adapter. The same Python commands run in GitLab CI
or any other CI system with Python 3.

## Ownership and flow

| Layer | Owner | Direction |
|---|---|---|
| Policy and rendered-link engines | `fork-sync-all` | Fork-Sync-All → profile source |
| Personal/profile content | `Interested-Deving-1896` profile repo | Profile source → OSP/OOC |
| OSP and OOC generated content | Their named README projects | Generated consumers only |

This is intentionally not a bidirectional file mirror. Every artifact has one
owner. Reusable improvements made while working in a profile repository are
contributed back to Fork-Sync-All, then flow forward from the canonical owner.
That promotion path prevents an update from bouncing indefinitely among four
repositories.

The three profile repositories remain the reference skeleton: they demonstrate
policy checks, preview artifacts, content smoke tests, repository audits,
mdBook/GitBook sources, Pages deployment, accessibility, and organization-
specific content. Fork-Sync-All owns only the reusable engines and coordination.

## Commands

```bash
python3 scripts/readme-subsystem.py validate
python3 scripts/readme-subsystem.py plan
python3 scripts/readme-subsystem.py sync \
  --target interested-deving-1896 \
  --target-root /path/to/profile-checkout
```

Add `--check` to the sync command to report drift without writing. The engine
only works on local checkouts; authentication, cloning, review branches, and
push policy remain responsibilities of the CI adapter for each forge.

## Safe continuous cross-porting

The GitHub workflow validates the contract on every relevant change and
reconciles the canonical artifacts into the profile source on `main` and on its
weekly schedule. The profile source's existing publisher then fans them out to
OSP and OOC. Other forges can call the same local sync command from their CI.

For production deployments, keep write credentials scoped to the target
project and prefer pull/merge requests when branch policy requires review.
