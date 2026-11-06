# Fork-Sync-All Self-Operation Engine

The Self-Operation Engine is the operational acceptance layer for Fork-Sync-All
itself. It is not a replacement for the project-creation, workflow-dispatch,
mirror-chain, credential, runner, or lifecycle engines. It composes those
capabilities through adapters and verifies their postconditions independently.

## Lifecycle

The engine orders declared operations by a deterministic dependency graph,
checks adapter capabilities, applies the selected execution mode, verifies
read-back state, attempts reconciliation after failures, and records redacted
lifecycle events.

## Modes in this first implementation

- **plan** (default): validates and orders the manifest. It performs no adapter
  reads or writes.
- **audit**: performs adapter inspection only. It never calls execute. Audit
  requires a real configured adapter through the Python API; the CLI deliberately
  exposes plan mode only so an unconnected placeholder cannot report a false
  successful inspection.
- **sandbox**: available only to adapters explicitly marked `sandbox=True`;
  mutating operations require explicit authorization and an exact target
  allowlist. Success requires independent `verify` read-back.
- **live**: deliberately unavailable. It must not be enabled until protected
  environment approval, a dedicated least-privilege runtime credential,
  exact operator confirmation, disposable-resource allowlisting, durable
  recovery, and cleanup verification are integrated and tested.

The engine itself never accepts or stores credentials. A trusted host supplies
an `ExecutionPolicy`; CLI arguments alone cannot grant mutation authority.

## Manifest

Version 1 manifests are JSON:

```json
{
  "version": 1,
  "operations": [
    {"id": "inspect-self", "capability": "repo.inspect", "target": "self"},
    {"id": "verify-seed", "capability": "repo.seed", "target": "sandbox/repo",
     "depends_on": ["inspect-self"], "mutating": true,
     "expected": {"files": ["README.md"]}}
  ]
}
```

Run a deterministic plan:

```sh
python3 scripts/self_operation_engine.py config/self-operation-manifest.json --mode plan
```

Run read-only inspection with a configured adapter through the Python API:

```python
from scripts.self_operation_engine import SelfOperationEngine, JsonlJournal
report = SelfOperationEngine(adapter).run(operations, mode="audit",
    journal=JsonlJournal("/secure/path/self-operation.jsonl"))
```

## Outcomes and evidence

Operation outcomes are explicit: `planned`, `audited`, `verified`,
`unsupported`, `blocked`, `denied`, `failed`, and
`verification_failed`. API acceptance is not proof of success. The final
run status is `verified` only when every operation has independently verified
postconditions.

The JSONL journal is append-only and created with owner-only permissions.
Secret-like fields are redacted recursively. Do not journal raw logs, signed
URLs, tokens, or complete provider response bodies.

## Current limitations

This initial slice provides the provider-neutral orchestration contract,
deterministic planner, read-only modes, sandbox adapter boundary, verification,
reconciliation hook, redacted journal, CLI manifest planner, and offline tests.
It does not yet include production GitHub/GitLab adapters, workflow discovery,
automatic live dispatch, real mirror writes, or live repository creation.
Those integrations must reuse existing engines and remain individually
policy-gated. Unavailable capabilities are reported as unsupported rather
than being presented as proof that the platform is operational.
