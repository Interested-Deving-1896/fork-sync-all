# CI Infrastructure Incident and Verified Recovery

This document describes the first offline policy layer for issue #1033. It is
intentionally not a second runner manager, scheduler, queue registry, provider
adapter, or authorization service.

## Ownership and integration

- Runner inventory, capabilities, health/readiness, leases, and capacity
  observations remain owned by the Runner Lifecycle & Capacity Engine (#1015).
- All mutations remain subject to the Global Authorization Gate (#1011).
- Transport failures and bounded retry mechanics must reuse #658.
- Existing queue/capacity observations remain the source inputs; this module
  does not poll providers or write telemetry.

## Offline policy primitives

`scripts/fsa_ci_recovery.py` provides deterministic functions for:

1. Failure classification. Only explicit affirmative evidence selects a
   category. Missing or conflicting evidence remains unknown.
2. Retry planning. Non-retryable, non-idempotent, over-budget, and saturated
   operations are suppressed. Delay is bounded and honors Retry-After without
   performing a retry.
3. Shard integrity. The expected and observed shard identifiers must be an
   exact unique set before aggregate success is possible.
4. Capability compatibility. Every declared requirement must match; a Linux
   candidate cannot satisfy a macOS requirement.
5. Recovery verification. Fresh connectivity, runner readiness, queue
   stability, task initialization, complete shards, and a successful canary
   are all required. A provider status page alone is insufficient.

These functions produce decisions and evidence summaries only. They do not
authorize or execute retries, cancellation, dispatch, provisioning, failover,
concurrency changes, or production resumption.

## State semantics

- `recovered`: every independent required check passed with fresh evidence.
- `unknown`: evidence is missing, stale, failed, or otherwise insufficient.
- Failure classification `unknown` is a valid result, not an exception.

The runner-status defect tracked by PR #883 remains separately owned there:
skipped or unavailable observations must not be reported healthy. This work
must consume corrected health semantics rather than duplicating that fix.

## Validation

The companion unit tests cover classification ambiguity, retry suppression and
bounds, exact shard accounting, capability mismatch, and independent recovery
evidence. Fake-provider scenarios simulate a datacenter capacity outage,
macOS-to-Linux incompatibility, missing shards, provider-green false recovery,
and a fully verified recovery. These tests are offline and do not contact providers.

## Deferred integration

The next stages are fake-provider contract tests, deterministic incident
fault-injection scenarios, read-only integration with #1015 telemetry, and
end-to-end simulated recovery. Live provider actions remain disabled and
require separately scoped authorization through #1011.
