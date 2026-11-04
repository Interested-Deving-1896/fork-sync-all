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


## Dashboard integration

The Dashboard engine is a complementary presentation layer, not another
documentation renderer and not a second control plane. The intended flow is:

```text
Project repositories + CI/workflow providers
                 |
                 v
       Fork-Sync-All control plane
   manifests / policy / lifecycle / status
                 |
        versioned read-only data
                 |
                 v
       Shared Dashboard engine
       |                 |
       v                 v
  Project views      Documentation views
       |                 |
       +--------+--------+
                |
       links to canonical sources
```

For Union, the shared dashboard should expose a project entry that links to
the canonical project repository and its generated documentation. Where
available, it may show validated build/test status, recent releases, workflow
health, documentation freshness, license/provenance review state, and related
upstream references. KDE/union should be clearly labelled as an external
upstream/reference until a fork relationship is proven; it must not appear as
a writable managed consumer.

### Data and responsibility boundaries

- Fork-Sync-All owns repository inventory, project identity, policy decisions,
  lifecycle state, and normalized status collection.
- The Dashboard engine owns navigation, presentation, filtering, and
  visualization. It must not independently decide repository ownership,
  mirror eligibility, merge eligibility, or trust.
- Dashboard data should be sourced from existing manifests and workflow
  artifacts where possible. Avoid a parallel crawler or a second registry.
- Publish a versioned, provider-neutral read model (for example, project
  identity, source links, lifecycle state, documentation targets, and
  timestamped CI/workflow summaries). Provider-specific IDs and raw payloads
  remain adapter details.
- Treat missing, stale, or permission-denied data as unknown/stale—not as
  success. Display collection time and source for operational status.
- Default dashboard integrations are read-only. Any future action controls
  must call an authorized Fork-Sync-All workflow/API, apply the same policy
  gates, require explicit confirmation for consequential operations, and
  record an audit trail.
- Never expose secrets, tokens, private workflow logs, protected variables,
  or sensitive environment metadata in dashboard data or client bundles.

### Reusable ecosystem views

The same project contract can power:
- a project overview with repository, documentation, releases, and CI links;
- a documentation hub that opens the README, mdBook, and optional GitBook
  publication from one project record;
- an ecosystem view showing verified relationships (owned project,
  upstream/reference, mirror, or consumer) without conflating them;
- lifecycle and maintenance views showing actionable drift while preserving
  the control plane as the authority for remediation.

### Rollout and acceptance

1. Audit the existing `vendor/infra-dashboard` integration, its data
   contracts, deployment workflow, and current `VITE_*` configuration.
2. Reuse its existing project and status views where they fit; extend the
   shared schema rather than creating a Union-only dashboard.
3. Add Union only after its repository identity, source role, and status
   sources are validated. Keep KDE/union as a linked external reference.
4. Verify the dashboard consumes generated documentation URLs and
   versioned status artifacts without copying or independently editing docs.
5. Test stale/unknown states, missing permissions, malformed manifests,
   and unavailable providers. No unknown state may be rendered as healthy.
6. Keep all action capabilities disabled until authorization, policy checks,
   audit logging, and confirmation flows are implemented and tested.

Dashboard integration is therefore in scope for the Union ecosystem work,
but it is a separate adapter/read-model stage after the repository and
documentation baseline is verified. It does not require a new rendering
engine or direct writes to either Union repository.

## Qt/QML frontend and unified experience platform

The longer-term target is a shared Fork-Sync-All experience platform with
multiple consumers of the same provider-neutral project contract. KDE Union
can supply the visual styling layer for a native Qt Quick/QML frontend; it
does not replace the application shell, navigation, domain models, data
services, or the Fork-Sync-All control plane.

### Responsibility split

```text
                 Fork-Sync-All control plane
       identity / policy / project creation / lifecycle
                 status collection / authorized actions
                              |
                  versioned read-only API
                              |
                   shared project read model
                              |
        +---------------------+---------------------+
        |                     |                     |
        v                     v                     v
 Web dashboard         Qt Quick / QML app      Docs & README
 existing SPA          native FSA frontend     canonical Markdown
        |                     |                     |
        +---------------------+---------------------+
                              |
                 shared design tokens / navigation
                              |
                 status + project + docs links
```

The same project/read-model contract should feed the existing web dashboard
and a future desktop frontend. The README subsystem, DOCS/mdBook, GitBook OSS,
and multi-engine exporters remain documentation and publishing consumers;
they should not be embedded as competing UI frameworks. The Qt application
may render Markdown or open published documentation, but the canonical
content remains in the shared Markdown source tree.

### What KDE Union contributes

KDE Union is a Qt style engine with a Qt Quick output and optional Kirigami
integration. Its documented usage selects the style through
`QT_QUICK_CONTROLS_STYLE=org.kde.union`. This makes it a suitable candidate
for consistent Qt Quick Controls styling, not a complete dashboard or
application framework.

A Fork-Sync-All QML frontend would still need:
- an application shell, navigation model, page routing, and responsive
  desktop/window layouts;
- reusable QML components for project cards, repository relationships,
  workflow status, documentation navigation, lifecycle timelines, and
  settings;
- typed client-side view models backed by the provider-neutral FSA API;
- explicit loading, empty, stale, unknown, permission-denied, and error states;
- accessible keyboard navigation, focus handling, scalable layouts, and
  platform-aware interaction;
- a safe action boundary: read-only by default, with consequential actions
  delegated to FSA policy-gated workflows and confirmation/audit mechanisms.

### Proposed frontend baseline

Keep this as a separately buildable application/template, for example:

```text
apps/fsa-desktop/
  CMakeLists.txt
  README.md
  src/
    main.cpp
    api/
    models/
    services/
  qml/
    Main.qml
    AppShell.qml
    components/
    pages/
    theme/
  tests/
```

The exact path and module layout are proposals, not existing repository
contents. Prefer Qt 6 / Qt Quick Controls 2 and evaluate Kirigami for KDE
desktop integration. Use KDE Union as an optional/selectable style provider
where compatible with the supported Qt/KF dependency matrix. Do not hard-code
a dependency on a moving KDE master branch: pin tested releases or commits,
record license and attribution, and retain a fallback Qt style for
non-KDE platforms.

### Shared UI and documentation contract

- Project identity, relationships, lifecycle, and status come from the same
  versioned FSA read model used by the web dashboard.
- README, DOCS, mdBook, GitBook, and exported books remain canonical-source
  and publishing concerns. UI surfaces link to the correct canonical or
  published targets rather than copying their content into a second CMS.
- Shared design tokens and component semantics should be documented in
  Markdown and mapped to both web and QML implementations; visual parity
  does not require identical rendering technology.
- Dashboard widgets and QML pages must distinguish verified facts from
  unavailable or stale data and display provenance/collection timestamps.
- No frontend may contain PATs, workflow secrets, private logs, or privileged
  credentials. The desktop client must not bypass FSA authorization by
  calling provider APIs directly for privileged operations.

### Delivery gates

1. Audit the existing dashboard's frontend, backend/API, configuration,
   deployment, and authentication boundaries before defining or changing
   its API.
2. Define and validate a versioned project/status read-model schema shared
   by web and Qt clients; add fixtures for healthy, stale, unknown,
   permission-denied, and malformed-provider responses.
3. Prototype a minimal QML shell that reads fixture data only and demonstrates
   navigation, project overview, workflow health, and documentation links.
4. Build against a documented Qt/KF/Union compatibility matrix; run QML,
   unit, accessibility, and packaging smoke tests on supported platforms.
5. Connect the shell to a read-only FSA API adapter, then add any action
   surfaces only after authorization, confirmation, and audit tests pass.
6. Publish the frontend as a reusable FSA template only after clean builds,
   tests, documentation, licensing, and a reproducible setup path are verified.

This gives Fork-Sync-All one coherent product experience without collapsing
the distinct responsibilities of its control plane, dashboard, documentation
publishers, and native UI.
