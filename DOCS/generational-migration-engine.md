# Generational Migration Engine (GME)

## Purpose

GME coordinates controlled, auditable change migration between distinct generations of a project. Generations may have different languages, architectures, APIs, directory layouts, and release lifecycles. The engine preserves provenance and treats semantic translation as reviewable work—not an automatic cherry-pick or branch sync.

## Penguins-Eggs lineage pilot

The pilot models two distinct implementations:

| Generation | Local fork / branch | Canonical upstream / branch | Technology |
|---|---|---|---|
| Legacy | `Interested-Deving-1896/penguins-eggs:all-features` | `pieroproietti/penguins-eggs-legacy:master` | Node.js / TypeScript |
| Modern | `Interested-Deving-1896/oa-tools:main` | `pieroproietti/penguins-eggs:main` | C / Go |

The old upstream name `pieroproietti/penguins-eggs` now identifies the legacy repository's successor lineage; the current C/Go project uses that canonical name, while the user's modern downstream fork is still named `oa-tools`. The former upstream `pieroproietti/oa-tools` is recorded as a historical alias of the modern generation.

The local branches contain substantial downstream history and are diverged from their upstream branches. They must not be force-synced, renamed, rebased, or merged as part of this pilot. The registry separates local repository/branch identity from canonical upstream repository/branch identity so that those operations cannot be inferred from a project name alone.

The relationship is `successor-project`, not a conventional fork relationship between the two generations. The mapping is deliberately marked `initial-placeholder`: exact file, symbol, command, and API correspondences must be audited before migration automation.

## Components / future adapters

- **Lineage mapping:** repository, branch, commit, release, historical alias, and generation identity.
- **Forward migration:** legacy → modern.
- **Backport and compatibility:** modern → legacy.
- **Semantic change analysis:** classify changes and identify correspondences.
- **Migration verification:** run source and target checks and compare behavior.
- **Conflict resolution:** explain ambiguity and route it to a maintainer.

## Modes

| Mode | Meaning |
|---|---|
| Mechanical candidate | Potentially safe documentation/metadata operation; still validated |
| Assisted | Propose an adaptation; tests and review required |
| Manual | Record the obligation; a maintainer implements the translation |

## Safety model

1. No automatic source or target edits in the initial planner.
2. Matching filenames do not imply semantic equivalence.
3. Bug-fix migrations retain source-commit provenance and require validation.
4. Architecture and feature changes remain manual unless a mapping is explicitly verified.
5. Plans record source commits and planned status.
6. Human review is mandatory for semantic or uncertain transformations.
7. Completion requires source tests, target tests, and review evidence.
8. The planner does not synchronize upstream branches or mutate either fork.

## CLI

```sh
python3 scripts/generational_migration_engine.py config/generational-migration/penguins-eggs.json --changes changes.json --output migration-plan.json
```

`changes.json` is a JSON array, for example:

```json
[
  {
    "id": "commit-or-ticket",
    "kind": "bugfix",
    "source_commit": "full-source-commit-sha",
    "mapping_verified": false,
    "mapping": []
  }
]
```

## Next pilot stages

1. Pin source and target commit SHAs for each audit run.
2. Audit both repositories' commands, capabilities, APIs, tests, packaging, and supported distributions.
3. Establish curated symbol/API mappings with evidence and reviewers.
4. Exercise a documentation-only change end-to-end in a disposable test fixture.
5. Test one bug fix with a verified mapping and source/target validation.
6. Add provider-neutral CI adapters only after planner and mapping semantics stabilize.
7. Keep any future repository rename, branch rewrite, upstream synchronization, or cross-generation code migration as a separately reviewed operation.
