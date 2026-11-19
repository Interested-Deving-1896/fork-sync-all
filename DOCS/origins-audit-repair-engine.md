# Origins Audit & Repair Resolver Engine

## Purpose

A read-only, relationship-aware audit of upstream projects listed in
`dep-graph/provenance.yml`. It produces a machine-readable inventory, checks
registry completeness, and (optionally) probes public canonical URLs. It does
**not** clone, patch, push to, or open PRs against upstream repositories.

## Run

```bash
python3 -m pip install pyyaml
python3 scripts/origins_audit_repair_engine.py
python3 scripts/origins_audit_repair_engine.py --online --output origins-audit.json
python3 scripts/origins_audit_repair_engine.py --online --fail-on-findings
```

- Default: registry-only, deterministic, no network access.
- `--online`: GET public origin URLs. Failures may reflect rate limits, temporary
  network errors, redirects, repository renames, archives, or deletion; treat
  them as triage signals, not definitive proof of removal.
- `--fail-on-findings`: CI-friendly nonzero exit on invalid registry rows or
  remote checks that are not reachable.
- JSON output contains provenance relationship, declared artifact, registry
  issues, remote status, and a conservative repair suggestion.

## Relationship-aware policy (next expansion)

| Relationship | Recommended audit depth |
|---|---|
| `fork`, `extracted-logic` | Code, license, security, maintenance, upstream/downstream divergence |
| `schema-adopted`, `pattern-adopted` | Schema/pattern drift and attribution |
| `inspired-by`, `reference` | Link/repository health and attribution only by default |

## Safety / roadmap

1. Registry and canonical-URL validation (implemented).
2. Read-only URL availability report (implemented; online checks are opt-in).
3. Relationship-specific metadata/code health audits.
4. Repair plan generation with provenance and confidence.
5. Isolated local branches and tests for **this repository's** artifacts.
6. Draft PR creation only after explicit workflow policy; no upstream writes
   without separate user authorization.

Repair suggestions are proposals. Human review remains required for licenses,
security, attribution, renamed/deleted repositories, and any upstream changes.
