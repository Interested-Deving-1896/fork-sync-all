# GitHub Diagnostic Read Adapter (Check Runs)

This is a bounded, read-only adapter slice for issue #1023. It retrieves
GitHub Check Runs annotation pages and normalizes them into the provider-neutral
diagnostic evidence contract.

## Important correlation boundary

The adapter accepts explicit check-run IDs only. Before retrieving annotations,
call `GitHubCheckRunVerifier.verify(provenance, check_run_ids)` from
`scripts/github_check_run_verifier.py`. It fetches the exact attempt endpoint,
checks the returned run ID, attempt number and full head SHA, then paginates the
attempt-specific jobs endpoint and matches each job's `check_run_url` to the
requested check-run ID. It rejects missing links, mismatched jobs and incomplete
pagination. It returns the verified `{check_run_id: job_id}` mapping. Only after
that succeeds should the caller invoke `GitHubCheckRunsAdapter.fetch_annotations`.
The verifier never guesses a "latest" attempt or silently substitutes another run.

The normalized annotations retain the supplied check-run ID and requested
full head SHA. Annotation endpoint payloads do not independently supply these
fields, so these values are attached only after the caller-supplied identity
precondition. This is not a substitute for that precondition.

## Bounds and failure handling

- HTTPS requests are restricted to `api.github.com`.
- Authenticated API redirects are accepted only when they remain on the same
  API origin; cross-origin redirects are rejected.
- Each response is capped (default 2 MiB), each page is capped by a maximum
  page count (default 20), and the operation has an overall deadline
  (default 45 seconds).
- Requests use bounded timeouts and retry only transport failures and
  GitHub's 429/5xx transient statuses. Retry-After is capped at five seconds.
- 403/404/429 exhaustion/5xx exhaustion and malformed responses are not
  converted into empty successful results.
- A page-limit stop after receiving evidence is represented as partial;
  failures before any page is read are represented as failed.
- Zero annotations across a fully retrieved response is a valid success.

## Integration status

This adapter is intentionally not wired into `pipeline-telemetry.sh`. The
current shell path still needs exact run-attempt metadata verification,
attempt-specific jobs pagination, bounded log ZIP retrieval, safe redirect
handling that never forwards the GitHub bearer token to signed external log
storage URLs, restrictive temporary-file permissions, guaranteed cleanup,
and end-to-end regression tests. No production workflow behavior changes here.

## Tests

Run:

```sh
python3 -m unittest tests.test_diagnostic_evidence tests.test_github_diagnostic_adapter
```
