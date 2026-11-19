# Diagnostic Evidence Contract (v1)

This module is the provider-neutral, read-only evidence layer for issue #1023.
It is designed to be consumed by the existing log-fetch/telemetry path; it is
not a second fetcher or workflow orchestrator.

## Contract

- `Provenance` binds evidence to owner/repository, run ID, attempt, full head
  SHA, and optional branch/ref, PR, job, and check-run identifiers.
- `verify_correlation` rejects missing or mismatched repository/run/attempt/SHA
  values. Optional job/check-run IDs are exact-match constraints when supplied.
- `EvidenceRecord` preserves distinct retrieval outcomes: success (including
  a valid zero-record result), partial, unavailable, unsupported, expired, and
  failed. Partial results require an explanation.
- `normalize_annotation` validates annotation identity, safe relative paths,
  severity and line ranges before producing a stable provider-neutral record.
- `build_audit_report` redacts record values and errors before presentation,
  marks every non-success result incomplete, and attaches a deterministic
  SHA-256 digest to the redacted evidence payload.

## Adapter boundary

Provider adapters own authentication, HTTPS/redirect validation, pagination,
timeouts, retries, byte limits, and endpoint-specific status classification.
They must verify the requested execution identity before constructing evidence.
They must not convert 403/404/429/5xx, expired log URLs, or network failures into
a successful empty result. Pagination that stops early must be represented as
partial evidence with an error and page counts.

The GitHub adapter should use check-run metadata and annotation endpoints
separately from Actions job logs. Workflow log commands such as
`::warning::` are not equivalent to Check Runs API annotations.

## Privacy and authority

- This contract performs no network calls and reads no credentials.
- Redact bearer credentials, common GitHub token formats, credential-bearing
  URLs, and signed URL query strings before excerpts are displayed or digested.
- Raw logs are not persisted by this module.
- Evidence is diagnostic only. It grants no authority to rerun workflows,
  dispatch jobs, edit source, create commits, merge PRs, or write mirrors.
- Persist only redacted summaries/digests unless a separate retention policy
  explicitly authorizes otherwise.

## Validation

Run the focused offline tests with:

```sh
python3 -m unittest discover -s tests -p 'test_diagnostic_evidence.py' -v
```

No network or provider credentials are required.
