# Upstream Engine — implementation status

The executable slice is intentionally **report-only**. It accepts either an explicit
list of `OWNER/NAME` repositories or one or more GitHub organizations, reads repository
metadata from the GitHub REST API, and emits deterministic JSON or Markdown. It does not
clone repositories, execute project code, create branches or pull requests, or modify
source repositories.

## Run locally

Inspect explicitly selected repositories:

```sh
python3 scripts/upstream_engine.py --repo owner/project --format json
GH_TOKEN=... python3 scripts/upstream_engine.py --repo owner/project --format markdown --output report.md
```

Discover all public repositories in one or more organizations:

```sh
GH_TOKEN=... python3 scripts/upstream_engine.py \
  --org akamai-developers \
  --org linode \
  --format json --output organization-inventory.json
```

Optional exact-name and category filters:

```sh
python3 scripts/upstream_engine.py --org linode \
  --allow linode/linodego --allow linode/terraform-provider-linode \
  --category sdk-cli --category iac --format markdown
```

A token is optional for public repositories. Use a read-only token if one is
needed for rate limits. The manual workflow `Upstream Engine report` exposes the
same repository and organization inputs and uploads a short-lived report artifact.

## Organization discovery behavior

- Uses GitHub's public organization repositories endpoint with 100-item pagination.
- Sorts organizations and repositories deterministically.
- Records repository URL, description, visibility, archive/disabled/fork state,
  default branch, language, topics, creation/push timestamps, license identifier,
  and a deterministic metadata-keyword category.
- Reports archived repositories but marks them as non-candidates by default.
- Marks disabled repositories as non-candidates.
- Supports exact allow/deny filters and category filters.
- Keeps discovery separate from `registered-imports.json`: it never registers,
  forks, mirrors, or writes to discovered upstream repositories.
- Classification is a triage aid based on metadata, not a security or suitability
  verdict. Repository contents, license text, release compatibility, maintenance
  quality, and security posture require a later review.

## Current evidence and limits

- Archived status, disabled status, fork status, default branch, timestamps and SPDX
  identifier are taken from repository metadata.
- Fork parent/source metadata is reported as lineage evidence; a non-fork archived
  repository is never assigned a guessed canonical upstream.
- A repository with no push in at least 365 days is marked a stale candidate. This
  is a review signal, not proof that it is abandoned or unsafe.
- Organization discovery uses GitHub REST metadata only. It does not inspect source
  files, tags/releases, dependency manifests, SBOMs, vulnerabilities, build systems,
  tests, successor candidates, or compatibility.

## Next implementation gates

1. Add provider-neutral repository and release adapters (GitHub first, then GitLab).
2. Inspect manifests, submodules, workflows, license files and provenance without
   executing untrusted project code; emit a versioned SBOM and checksums.
3. Verify upstream/successor lineage with evidence and confidence scoring.
4. Add isolated compatibility/build validation with no production secrets.
5. Produce migration plans and patch previews; only later add opt-in branch/PR creation.
6. Keep merge, release, deployment, history rewrite and unarchive operations behind
   explicit human approval.

The workflow remains manually dispatched. No scheduled organization scans or
automatic import actions are enabled.
