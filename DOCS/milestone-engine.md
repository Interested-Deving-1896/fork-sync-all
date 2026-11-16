# Fork-Sync-All Milestone Engine

The Milestone Engine provides a provider-neutral, read-only planning and
verification layer. The canonical JSON manifest is the source of truth;
GitHub/GitLab milestone objects are optional projections and are not required
for evaluation.

## Run

```sh
python3 scripts/milestone_engine.py config/milestone-manifest.json
python3 scripts/milestone_engine.py config/milestone-manifest.json --now 2026-11-05T18:00:00Z
```

The optional `--now` value makes freshness evaluation reproducible. The
engine performs no network requests and no provider writes.

## Manifest

Version 1 uses `schema_version: 1` and a `milestones` array. Each milestone
has a stable `id`, `title`, optional owner/priority/target date, declared
status, dependencies, deliverables, and acceptance criteria. A criterion may
contain an evidence object with a stable reference, state, timezone-aware
observation timestamp, and optional maximum age in seconds.

Evidence states are `verified`, `failed`, and `unknown`. Missing or stale
evidence is never interpreted as success. Evidence references should identify
immutable commits, workflow run/job results, artifact digests, or other
independently inspectable records; a provider's accepted write response alone
is not proof.

## Planning and status

Dependencies are cross-milestone IDs and are ordered deterministically. Missing
references, duplicate IDs, self-dependencies, and cycles fail validation.
Progress is the percentage of mandatory acceptance criteria with fresh
verified evidence. Optional criteria do not affect the percentage.

A milestone is completed only when it has at least one mandatory criterion,
all mandatory criteria are freshly verified, and all dependencies are
completed. Failed criteria or incomplete dependencies block completion.
Missing, unknown, or stale evidence yields unknown/verifying rather than
silently passing. Cancelled milestones remain cancelled.

## Provider adapters and safety

This first slice intentionally has no provider adapter and no mutation path.
Provider discovery, GitHub/GitLab projection, and drift remediation are future
adapter work. They must preserve canonical IDs and evidence provenance, report
pagination/incomplete reads, and remain read-only until separately authorized.
Milestone completion never authorizes merges, issue closure, branch changes,
workflow dispatch, mirror writes, credential changes, or protected-setting
changes. Existing lifecycle, policy, project/template registries, and branch
topology remain authoritative for their respective domains.
