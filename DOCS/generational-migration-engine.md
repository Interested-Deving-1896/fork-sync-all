# Generational Migration Engine (GME)

## Purpose

GME coordinates controlled, bidirectional change migration between distinct generations of a project. Unlike branch synchronization, generations may have different languages, architectures, APIs, directory layouts, and release lifecycles. The engine preserves provenance and treats semantic translation as reviewable work—not an automatic cherry-pick.

## Initial Penguins-Eggs pilot

- **Legacy:** `Interested-Deving-1896/penguins-eggs`, branch `all-features`, Node.js/TypeScript.
- **Modern:** `Interested-Deving-1896/oa-tools`, branch `main`, C/Go.

The relationship is `successor-project`, not a conventional fork. Repository identity, project identity, and generation identity are separate fields. The pilot mapping is deliberately marked `initial-placeholder`: exact file/symbol/API mappings must be audited before migration automation.

## Components / future adapters

- **Lineage Mapping:** repository, branch, commit, release and generation identity.
- **Forward Migration:** legacy → modern.
- **Backport & Compatibility:** modern → legacy.
- **Semantic Change Analysis:** classify changes and identify correspondences.
- **Migration Verification:** run source and target checks and compare behavior.
- **Conflict Resolution:** explain ambiguity and route it to a maintainer.

## Modes

| Mode | Meaning |
|---|---|
| Mechanical candidate | Potentially safe metadata/docs operation; still validated |
| Assisted | Propose adaptation; tests and review required |
| Manual | Record obligation; maintainer implements translation |

## Safety model

1. No automatic source edits in this initial planner.
2. Matching filenames do not imply semantic equivalence.
3. Bug-fix migrations retain provenance and require validation.
4. Architecture/features remain manual unless a mapping is verified.
5. Plans record source commit and status.
6. Human review is mandatory for semantic or uncertain transformations.
7. Completion requires tests and review evidence.

## CLI

```sh
python3 scripts/generational_migration_engine.py config/generational-migration/penguins-eggs.json --changes changes.json --output migration-plan.json
```

`changes.json` is a JSON array, e.g. `[{"id":"commit-or-ticket","kind":"bugfix","source_commit":"abc123","mapping_verified":false,"mapping":[]}]`.

## Next pilot stages

1. Audit both repositories and pin commit SHAs.
2. Establish canonical generation metadata and rename/rebrand history.
3. Build a curated symbol/API mapping manifest.
4. Exercise a docs-only change end-to-end.
5. Test one bug fix with verified mapping and cross-generation validation.
6. Add CI adapters only after planner and mapping semantics stabilize.
