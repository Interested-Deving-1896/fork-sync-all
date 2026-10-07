# Forge-neutral README subsystem

The README subsystem separates reusable automation from profile identity and
uses forge-neutral terms throughout its contract:

- a **namespace** may be a GitHub organization or user, a GitLab group or
  subgroup, a Gitea/Forgejo organization, or another forge's equivalent;
- a **project** is the hosted Git repository;
- a **profile surface** is whichever README location a forge chooses to expose.

The machine-readable contract is `config/readme-subsystem.json`, validated by
`schema/readme-subsystem.schema.json`. The local engine is
`scripts/readme-subsystem.py`, and `readme-subsystem/action.yml` provides the
GitHub Actions adapter. The same Python commands run in GitLab CI or any other
CI system with Python 3. Tested contract fixtures cover GitLab groups and
subgroups, Gitea organizations, Forgejo/Codeberg namespaces, and generic Git
workspaces.

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
python3 scripts/readme-subsystem.py lock --check
python3 scripts/readme-subsystem.py plan
python3 scripts/readme-subsystem.py sync \
  --target interested-deving-1896 \
  --target-root /path/to/profile-checkout
```

Add `--check` to the sync command to report drift without writing. The engine
only works on local checkouts; authentication, cloning, review branches, and
push policy remain responsibilities of the CI adapter for each forge.

To suggest a reusable improvement discovered in the profile source, generate a
review bundle instead of reverse-syncing files:

```bash
python3 scripts/readme-subsystem.py propose-upstream \
  --profile-root /path/to/profile-checkout \
  --output-dir /tmp/readme-subsystem-proposal
```

The bundle contains `proposal.json` with old and proposed checksums and a
unified patch. Applying or opening that patch upstream is always a separate,
human-reviewed action. Binary differences are reported for manual review.

## Releases and provenance

`readme-subsystem/VERSION` is the subsystem release, and
`readme-subsystem/CHANGELOG.md` records compatibility changes. Consumers
should pin the immutable release tag or the reviewed major tag:

```yaml
- uses: Interested-Deving-1896/fork-sync-all/readme-subsystem@readme-subsystem-v1
```

For maximum reproducibility, replace the major tag with an immutable commit
SHA. `config/readme-subsystem.lock.json` binds the release tag, contract, and
every canonical promoted artifact to SHA-256 checksums. Both GitHub and GitLab
CI reject stale provenance.

## Safe continuous cross-porting

The GitHub workflow validates the contract on every relevant change. On
`main` and its weekly schedule it publishes canonical changes to a dedicated
branch and opens or updates a pull request in the profile source. It never
pushes directly to the protected default branch. After review, the profile
source's existing publisher fans profile-owned content out to OSP and OOC.
Other forges can call the same local sync command from their CI.

The preferred credential is a GitHub App installed only on the profile source
with **Contents: write** and **Pull requests: write** repository permissions.
Set `README_SUBSYSTEM_APP_ID` as a repository variable and
`README_SUBSYSTEM_APP_PRIVATE_KEY` as a secret. `SYNC_TOKEN` remains a
transition fallback and should be removed once the App is configured.

For non-GitHub hosts, use a project-scoped bot credential and open a merge or
change request using that forge's adapter. The core contract deliberately uses
namespace/project terms and does not require an organization concept.

## Drift and operational status

`scripts/readme-subsystem-status.py` clones declared projects, checks canonical
engine checksums, verifies the Interested-Deving-1896 → OSP → OOC content
chain, and requests every configured Pages URL. The scheduled status workflow
publishes JSON and Markdown artifacts and maintains one GitHub issue as the
current dashboard. Drift is visible without allowing the monitor to modify any
profile repository.
