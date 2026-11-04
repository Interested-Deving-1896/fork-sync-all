# Union project integration

This document defines how the Union repositories can consume Fork-Sync-All's
existing README and documentation rendering systems without creating a
parallel renderer or confusing project ownership.

## Repositories and authority

| Repository | Role | Authority boundary |
|---|---|---|
| [Interested-Deving-1896/union](https://github.com/Interested-Deving-1896/union) | Project-owned repository | Owns its implementation, project identity, local documentation, release policy, and license declarations |
| [KDE/union](https://github.com/KDE/union) | KDE upstream/reference project | Authoritative source for KDE-originated implementation, upstream documentation, releases, and licensing where the project is demonstrably derived from it |

The repository names alone do not establish a fork relationship. The project
repository's current README says there is no upstream fork. Before adding an
upstream import, fork-sync, or mirror-chain registration, verify GitHub fork
metadata, commit ancestry, source history, license compatibility, and any
intentional divergence. If it is a clean independent project, record KDE/Union
as a related project or reference rather than configuring automatic sync.

Never write to `KDE/union` as part of this integration.

## Reuse the existing rendering stack

The integration should consume the existing Fork-Sync-All systems:

- README subsystem: structured README generation, explicit AI-owned regions,
  human-owned section preservation, and render validation.
- mdBook: Markdown source pages and navigation for maintained project docs.
- Multi-engine book export: mdBook, MkDocs, Docusaurus, and Pandoc adapters
  from the shared book-engine.
- GitBook OSS: optional renderer/export target using the existing
  `gitbook-oss.yml` workflow and adapter.

Markdown should remain the canonical documentation source. Renderer-specific
outputs are generated artifacts, not separately maintained content. A project
should only receive a published book when it has meaningful, reviewed
documentation and a valid navigation structure; placeholder pages must not be
published as authoritative documentation.

## Proposed project documentation layout

Adopt only after the project has sufficient source material:

```text
Interested-Deving-1896/union/
├── README.md
├── DOCS/
│   ├── SUMMARY.md
│   ├── README.md
│   ├── architecture.md
│   ├── building.md
│   ├── usage.md
│   └── development.md
└── book.toml
```

The list is a target layout, not a claim that these pages currently exist.
Keep build instructions grounded in the project's actual build system and
supported dependencies. KDE's current README describes Union as a Qt style
engine and documents Qt 6.9+, CMake, and the
[cxx-rust-cssparser dependency](https://invent.kde.org/libraries/cxx-rust-cssparser);
these details should only be carried into the project docs if provenance and
implementation inspection confirm they apply to this repository.

## README policy

- Preserve human-owned Install, Usage, Configuration, and other project
  sections.
- Replace the obsolete Ona badge only in a reviewed project README change;
  use provider-neutral AI-agent wording if a badge is appropriate.
- Do not invent a license. The current project README reports that no LICENSE
  file was detected; resolve this explicitly before publishing license claims.
- Preserve upstream attribution and required notices if the repository is
  derived from KDE/Union.
- Use the shared README renderer/validator rather than adding a project-only
  generator.

## Integration sequence

1. **Provenance and source audit:** inspect repository metadata, commit
   ancestry, code, license files, build manifests, tests, and existing docs.
2. **Project documentation baseline:** replace placeholders with verified
   project facts; retain human-owned content and establish a valid license.
3. **Rendering adapter:** add the project to the shared README validation
   contract and configure mdBook from Markdown sources.
4. **Optional render targets:** enable GitBook OSS and multi-engine exports
   only after mdBook build, link checks, and content review pass.
5. **Lifecycle integration:** add documentation freshness, navigation,
   broken-link, license/provenance, and generated-output checks to the
   lifecycle auditor.
6. **Registry integration:** register as a template consumer, upstream
   import, mirror-chain member, or project-creation template only after the
   relevant ownership and provenance contract is verified.

## Validation and safety

- README generation must preserve all human-owned sections.
- mdBook build and link validation must pass.
- Optional renderer exports must consume the same Markdown source.
- No generated book output should be committed unless the existing publishing
  contract requires it.
- License and provenance checks must be evidence-based and fail closed.
- No automatic sync or mirror writes to KDE/union.
- No default-branch changes to the project repository without a reviewed PR.
- No template injection should be enabled until the consumer profile and
  exclusions are audited for project-specific safety.

## Current assessment

The Fork-Sync-All README and book-rendering workflows already provide the
reusable foundation. The project repository's current README is still a
scaffold with placeholder sections and an obsolete Ona badge. This integration
therefore starts with provenance, license, and content discovery—not with
blindly enabling a publisher or injecting the full Fork-Sync-All template.
