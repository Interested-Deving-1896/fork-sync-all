# Origins and Code Archaeology Integration

**Status:** read-only offline integration slice; provider adapters and live reporting remain gated.

## Authority boundaries

The exchange is bidirectional for evidence, not for write authority.

- Origins declarations seed investigation requests.
- Code Archaeology emits revision-anchored observations into a proposal/review queue.
- Origins remains authoritative for declared provenance, relationship decisions, attribution, license review and approval.
- Code Archaeology remains authoritative for the observations it collected.
- Reconciliation is report-only. It cannot approve provenance, admit repositories, change mirror topology, edit README sections, dispatch sync, or update refs.

## Existing sources reused

- `dep-graph/provenance.yml`: structured human-maintained influence declarations consumed by the existing Origins README generator.
- `dep-graph/origins.md`: generated dependency/origin summary; do not edit manually.
- `config/live-chain-manifest.json`: canonical admitted mirror membership and README exceptions; this integration does not create a second registry.
- Existing README Origins generation/validation paths remain the only writers of generated Origins sections.

The existing upstream-source sync workflow is not an archaeology backend. Its script can invoke GitHub `merge-upstream` and, as a fallback, a force ref reset. Do not dispatch it from this engine or share its write credentials with archaeology.

## CI validation

The dedicated read-only offline contract workflow is enabled on the default branch by [PR #992](https://github.com/Interested-Deving-1896/fork-sync-all/pull/992). Changes to the adapter, local evidence collector, schema or integration tests trigger the offline test suite on pull requests. The workflow has `contents: read` only and does not dispatch or mutate repositories.

## Offline contract

The JSON Schema is `schemas/origins-archaeology-evidence.schema.json` (schema version 1).

Origins -> archaeology:

```sh
python3 scripts/origins_archaeology.py seed --target-repository Interested-Deving-1896/fork-sync-all
```

This reads `dep-graph/provenance.yml` and emits read-only investigation requests to stdout. It does not execute Git commands or contact providers.

Local Git evidence collection:

```sh
python3 scripts/code_archaeology_evidence.py \\
  --source-repo /local/path/upstream \\
  --target-repo /local/path/project \\
  --source-name owner/upstream \\
  --target-name owner/project \\
  --source-revision <source-commit> \\
  --target-revision <target-commit> > evidence-package.json
```

The collector is offline and read-only. It compares regular-file blob object IDs in two explicitly selected local commit trees, with bounded tree-entry, output-size and observation limits. Exact blob identity is emitted as a **low-confidence, unknown-relationship candidate** with both path sets and revision anchors. It does not prove which repository originated the content, whether the content was copied, or whether licenses are compatible. It does not traverse history, infer fork direction, inspect symlinks/submodules, or contact a forge. Incomplete scans are marked incomplete; no-match results are not contradictions.

Archaeology -> Origins proposal queue:

```sh
python3 scripts/origins_archaeology.py propose --input evidence-package.json
```

The input package must use schema version 1. Each observation must identify source/target repositories, evidence kind and exact locator. Proposals preserve revisions, confidence, rationale, alternatives and coverage where supplied. They are explicitly marked `proposed-review-required`.

## Report-only reconciliation CLI

After generating a proposal queue, compare it with the current human-maintained declarations:

```sh
python3 scripts/origins_archaeology.py reconcile --input proposals.json
```

Use `--provenance PATH` to select a different declaration file. The command emits a JSON report with candidate matches, ambiguous results and incomplete/unavailable results. Even a complete candidate match remains `human-review-required`; it is not an approval or a write instruction.

The offline tests also exercise the parser against the repository's current `dep-graph/provenance.yml` structure. The parser is intentionally a small reader for the current simple `influences` list, not a general YAML implementation; new YAML constructs require explicit parser and fixture work before adoption.

## Reconciliation rules

- Matching declaration and observation is only a candidate match, not legal or authorship proof.
- Low/unknown confidence remains ambiguous.
- Incomplete history, missing objects, permission gaps or incomplete pagination remain unavailable/incomplete.
- Absence of evidence is never treated as evidence of absence.
- License compatibility and attribution require separate review; lineage signals do not establish either.

## Safety

No network/provider API, repository write, README write, mirror operation, workflow dispatch, branch/ref update or destructive sync is performed by these adapters. JSON is emitted to stdout for CI artifacts or a separately permissioned report consumer. Never pass provider write credentials to this code.

The local Code Archaeology MVP remains independently bounded and read-only. GitHub/GitLab adapters, cross-repository commit graph correlation and dashboard publication are subsequent gated milestones.
