# FSA Loop Detection & Prevention Engine

## Initial implementation (observe-only)

`scripts/loop_guard.py` is the first provider-neutral operation adapter. It
records metadata-only JSONL events and flags repeated identical operations
when their progress marker has not changed inside a configurable time window.

It does **not** cancel workflows, suppress writes, dispatch jobs, retry calls,
open issues, or mutate external systems. A suspected loop is an observation,
not an automatic verdict or enforcement action.

### Quick start

```bash
python3 scripts/loop_guard.py \
  --engine log-fetcher \
  --action fetch-run-log \
  --target 'owner/repo/actions/runs/123/job/456' \
  --request-fingerprint 'run=123;job=456;page=1' \
  --progress 'cursor=page-1' \
  --provider github \
  --repository owner/repo
```

The command prints one JSON result. Exit status remains zero for both normal
and suspected-loop observations so observe-only instrumentation cannot break
the caller's existing behavior.

### Configuration

- `FSA_LOOP_LEDGER`: ledger path (default `.fsa/loop-events.jsonl`).
- `--window-seconds`: look-back window (default 900).
- `--threshold`: identical no-progress observations before flagging (default 3).
- `--max-events`: retained event cap (default 5000).

The ledger is local to the execution environment unless a caller deliberately
provides a shared path. For cross-run detection, integrate a durable,
access-controlled store in a later phase. Do not upload raw logs or credentials.

### Identity and progress

Callers provide normalized resource identity and a non-secret request
fingerprint. Advancing pagination cursors or state-version markers must be
passed through `--progress`; a changed marker starts a new progress series.
Independent resources remain separate by target and repository.

### Current scope and gaps

This first slice detects repeated identical operations with unchanged progress.
It does not yet infer arbitrary workflow dependency cycles, mirror-origin
feedback, audit remediation cycles, or AI-agent semantic repetition. Those
require causal/parent IDs and adapters that instrument the relevant systems.
Do not claim coverage until each adapter has dedicated tests.

### Safety and retention

- Observe-only is the only supported mode.
- The ledger stores hashes of request/progress identity, not raw request bodies.
- Keep the ledger on trusted storage with bounded retention.
- Do not pass tokens, credentials, private payloads, or personal data as
  target, request fingerprint, progress, actor, or repository values.
- A future circuit breaker must be scoped, expiring, auditable, and separately
  validated; this implementation has no enforcement switch.
