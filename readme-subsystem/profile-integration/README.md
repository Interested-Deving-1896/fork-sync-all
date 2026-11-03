# Profile README project integration

The Interested-Deving-1896 profile repository is a first-class consumer and
integration surface for this subsystem, not merely a destination for a copied
README.

## Existing canonical engine port

The reusable engines and subsystem contract are owned by Fork-Sync-All and
are promoted to the profile repository through the readme-subsystem.yml
cross-port workflow. The profile repository currently contains the same
versioned action and consumer-workflow contract. Keep these single-writer
ownership boundaries intact:

- scripts/readme-subsystem.py, config/readme-subsystem.json, the schema,
  lock, action, and shared policy/link engines are canonical reusable
  subsystem components.
- scripts/profile_readmes.py, scripts/readme_ai.py,
  config/profile-targets.json, profile content, character/lore assets, and
  organization publication workflows are profile-owned integration
  components.
- Profile-owned components must be integrated through an explicit adapter or
  reviewed upstream proposal. Do not overwrite the canonical engine with
  profile-specific identity, credentials, target lists, lore, or generated
  README payloads.

## Profile functionality consumed by this subsystem

The profile integration surface is defined by these existing project
components:

| Component | Responsibility | Integration boundary |
|---|---|---|
| scripts/profile_readmes.py | Profile README validation, generation, and documentation publication | Invoke as a profile adapter; keep target identity in the profile repository |
| scripts/readme_ai.py | AI-assisted README support | Consume through provider-neutral inputs and outputs; never require one vendor |
| config/profile-targets.json | Explicit publication destinations and target policy | Treat as profile-owned configuration, not canonical global defaults |
| .github/workflows/publish-organization-readmes.yml | Allowlisted organization publication | Keep profile repository as the single writer for OSP/OOC outputs |
| DOCS/readme-subsystem.md and DOCS/README.md | Contract, operations, and documentation navigation | Keep ownership and propagation direction visible |

## Documentation propagation

The profile repository imports both Fork-Sync-All source trees into
DOCS/upstream/fork-sync-all/DOCS/ and DOCS/upstream/fork-sync-all/docs/. This
preserves the profile repository's own DOCS/ and README.md, while making the
complete operational and supplementary documentation available to its
mdBook/GitBook publication project.

The import is snapshot-based and reviewable. It is deliberately not a
bidirectional raw mirror: generated files, credentials, and profile identity
remain under their existing owners.

## Reverse contribution path

Improvements to profile-owned adapter functionality are proposed back to
Fork-Sync-All through the profile repository's
propose-readme-subsystem-upstream.yml workflow. The workflow generates a
checksum-aware review bundle; promotion into the canonical subsystem requires
review and a PR. This prevents sync loops and accidental ownership reversal.

## Validation expectations

- Validate the canonical subsystem contract and provenance lock.
- Run the README subsystem unit tests and policy/link checks.
- Validate profile target configuration and generated documentation in the
  profile repository.
- Confirm imported documentation matches both upstream trees at the recorded
  source commit.
- Keep the profile README and profile-owned docs untouched by the importer.
