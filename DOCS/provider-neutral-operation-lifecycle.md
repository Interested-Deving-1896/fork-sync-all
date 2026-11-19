# Provider-neutral Preflight and Postflight engines

**Status:** first deterministic core slice; offline and read-only. Not a production
interception, authorization, dispatch, or remediation service.

## Architecture

FSA exposes two independently callable evaluators over one operation identity:

1. Preflight evaluates declared requirements and collected evidence before an
   operation. It reports readiness, missing evidence, uncertainty, blockers and
   warnings. A ready result is not permission to execute.
2. Postflight correlates the same operation, target and pinned revision with
   reported acceptance-criterion outcomes and evidence. It reports passed,
   failed, partial, inconclusive or unverifiable results and follow-up needs.

The shared operation envelope is defined in
schemas/operation-lifecycle-v1.schema.json. The deterministic implementation is
scripts/operation_lifecycle.py.

## Input model

An operation declares operation_id, operation_type, target, revision,
non-empty acceptance_criteria, and policy required_evidence. Evidence records
carry stable IDs, kinds, trust/status labels, source, revision and locator.
Missing, stale, inaccessible, unknown or contradictory evidence remains visible;
it is never silently interpreted as a successful check.

## Safety and authority

- The core is offline and performs no network, credential, model, workflow or
  repository action.
- Preflight never authorizes an operation. Existing Global Authorization Gate,
  human approvals, protected workflows and canonical budget/quota controls remain
  authoritative.
- Postflight never repairs, rolls back, signs, publishes, flashes or deploys.
  Remediation is a separate operation with its own preflight and authorization.
- Origins remains the provenance authority. Code Archaeology, topology/linkage,
  artifact attestation and budget systems remain authoritative in their domains.
  Adapters may present their evidence; the core does not replace those authorities.
- Agent-generated observations are untrusted unless independently verified.

## Samsung downstream profile

Samsung is a downstream policy profile, not a fork of the generic engine.
Adapters may add evidence requirements for device/model/variant, pinned Android
base, firmware source and redistribution permission, One UI/CSC, kernel/vendor/
userspace compatibility, OTA metadata, filesystem/package artifacts and servicing
stages. Proprietary firmware handling, signing, physical-device writes, Odin/
Heimdall/Thor/ragnaroek operations, release and deployment remain separately
permissioned and gated. Offline fixtures must not require proprietary firmware.

## Current limitations and next integration steps

This slice validates the operation/evidence contract and evaluates supplied
evidence. It does not yet collect evidence from GitHub/GitLab, Origins, CI,
artifacts, runners, Android/AOSP or Samsung systems. It does not yet bind to the
existing budget governor or Global Authorization Gate. Those adapters must be
added incrementally and tested against their canonical authorities before the
engine can be called end-to-end or production-ready.

The Origins-first agent contract in PR #1058 is one optional evidence source,
not a second lifecycle authority. PR #1054 supplies the shared Origins parser
foundation. Keep both dependencies stacked and reviewed independently.
