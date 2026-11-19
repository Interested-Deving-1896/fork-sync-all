# GitHub Actions Attempt and Log Adapter

`scripts/github_actions_log_adapter.py` adds a bounded, read-only retrieval
primitive for issue #1023. It is wired into `pipeline-telemetry.sh` for exact-attempt run/job/log
retrieval. The shell consumer retains its existing span and report structure,
while the adapter supplies verified metadata and private temporary log files.

## Retrieval guarantees

- Fetches the exact `/actions/runs/{run_id}/attempts/{attempt}` resource.
- Requires the returned run ID, attempt number, and full head SHA to match.
- Paginates the attempt-specific jobs endpoint and verifies every job's
  run ID, attempt, and full head SHA before requesting logs.
- Applies an overall deadline, response byte ceiling, and maximum jobs-page
  count. It rejects incomplete pagination and malformed payloads.
- Requests the logs endpoint with GitHub authentication, but handles its
  redirect manually. The signed storage URL is fetched in a separate request
  with no Authorization header and must be HTTPS, credential-free, and not
  api.github.com.
- Reads ZIP entries in memory, rejects unsafe paths and oversized entries,
  and never extracts raw logs to disk.

## Integration and safety boundary

- The shell script first fetches the exact attempt metadata and validates run ID,
  attempt number, and full head SHA; the adapter independently fetches and
  verifies the same identity before jobs/log retrieval.
- Jobs are paginated and every job is correlated to the requested run,
  attempt, and SHA. Any mismatch or incomplete pagination fails closed.
- The log redirect is handled manually. GitHub credentials are sent only to
  `api.github.com`; the signed storage request carries no Authorization header.
- Raw log files are written only beneath a unique mode-0700 temporary directory,
  with mode-0600 files and an EXIT/signal cleanup trap. They are not uploaded as
  artifacts or embedded in trace JSON.
- Log excerpts are redacted before they are attached to spans or rendered into
  the step summary. The trace artifact retains severity counts only.
- A 404/204 log response is recorded as unavailable; HTTP 410 is recorded as
  expired; transport/redirect/archive failures are recorded as failed while
  preserving verified run/job metadata.
- Check Run IDs are derived only from attempt-specific job metadata, verified
  against the same run/attempt/SHA, and then used for bounded annotation
  pagination. No linked Check Runs is reported as unavailable rather than a
  false clean result; 403/404 and 410 annotation responses remain unavailable
  and expired respectively.
- Rolling issue updates remain separately guarded by `UPDATE_ISSUE`.

This is an implementation integration, not a claim that every provider or
every diagnostic source is complete. GitHub Check Runs annotations are now
orchestrated from the same attempt-specific job metadata and included as
redacted normalized records in the trace artifact and step summary. Normal CI
must pass on the exact PR head before the work is considered validated. No
live workflow dispatch or rerun is required.

## Offline tests

Run with the repository's scripts directory on Python's import path:

```sh
PYTHONPATH=scripts python3 -m unittest tests/test_github_actions_log_adapter.py tests/test_github_check_run_verifier.py tests/test_pipeline_telemetry_diagnostic_integration.py -v
```

The fake transport tests verify exact attempt identity, job identity,
external-storage credential isolation, and rejection of unsafe redirect
targets. No live workflow, secret, or repository mutation is required.
