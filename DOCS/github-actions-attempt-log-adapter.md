# GitHub Actions Attempt and Log Adapter

`scripts/github_actions_log_adapter.py` adds a bounded, read-only retrieval
primitive for issue #1023. It is intentionally separate from
`pipeline-telemetry.sh` until its output contract is integrated and regression
coverage demonstrates parity with the existing telemetry report.

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

## Remaining integration work

The existing shell telemetry script still uses a generic-run fallback,
non-paginated jobs retrieval, and `curl -L` with the GitHub token on the
logs request. Do not treat this adapter as production-integrated until
`pipeline-telemetry.sh` consumes this adapter (or equivalent safe behavior),
the old fallback and credential-forwarding path are removed, redaction is
applied before summaries, and end-to-end regression tests cover existing
report output. Raw logs must remain ephemeral and must not be added to trace
JSON or issue comments.

## Offline tests

Run with the repository's scripts directory on Python's import path:

```sh
PYTHONPATH=scripts python3 -m unittest tests/test_github_actions_log_adapter.py -v
```

The fake transport tests verify exact attempt identity, job identity,
external-storage credential isolation, and rejection of unsafe redirect
targets. No live workflow, secret, or repository mutation is required.
