# Upstream Engine — implementation status

The first executable slice is intentionally **report-only**. It accepts only an explicit
list of `OWNER/NAME` repositories, reads repository metadata from the GitHub REST API,
and emits JSON or Markdown. It does not clone repositories, execute project code,
inspect dependency manifests, create branches or pull requests, unarchive repositories,
or modify any source.

## Run locally

```sh
python3 scripts/upstream_engine.py --repo owner/project --format json
GH_TOKEN=... python3 scripts/upstream_engine.py --repo owner/project --format markdown --output report.md
```

A token is optional for public repositories and should be read-only. Do not pass write
credentials. The workflow `Upstream Engine report` exposes the same report-only operation
through manual dispatch and uploads the result as a short-lived artifact.

## Current evidence and limits

- Archived status, disabled status, fork status, default branch, timestamps and SPDX
  identifier are taken from repository metadata.
- Fork parent/source metadata is reported as lineage evidence; a non-fork archived
  repository is never assigned a guessed canonical upstream.
- A repository with no push in at least 365 days is marked a stale candidate. This is
  a review signal, not proof that it is abandoned or unsafe.
- Source contents, tags/releases, dependency manifests, SBOMs, vulnerabilities,
  license files, build systems, tests, successor candidates and compatibility have
  **not** yet been audited by this prototype.

## Next implementation gates

1. Add provider-neutral repository and release adapters (GitHub first, then GitLab).
2. Inspect manifests, submodules, workflows, license files and provenance without
   executing untrusted project code; emit a versioned SBOM and checksums.
3. Verify upstream/successor lineage with evidence and confidence scoring.
4. Add isolated compatibility/build validation with no production secrets.
5. Produce migration plans and patch previews; only later add opt-in branch/PR creation.
6. Keep merge, release, deployment, history rewrite and unarchive operations behind
   explicit human approval.

The checked-in configuration remains disabled by default. This workflow does not
change that setting and is manually dispatched only.


## Read-only manifest path inventory

The `scripts/upstream_manifests.py` module adds a second, opt-in library slice: given a repository and default branch, it reads the Git tree API and classifies candidate paths for Python, JavaScript, Rust, Go, Ruby, PHP, JVM, .NET, container, Nix, submodule, SBOM and license files. It does not fetch manifest contents, resolve versions, infer transitive dependencies, or execute repository code. A truncated Git tree is explicitly surfaced and must be treated as incomplete evidence. Unit tests cover classification and deduplication.
