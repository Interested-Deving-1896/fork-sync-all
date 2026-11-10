# GitHub Actions log-fetch cycle engine

`scripts/log_fetch_cycle_engine.py` is the bounded, read-only log retrieval
component used by CI failure diagnosis.

## Why it exists

GitHub job-log downloads can be temporarily unavailable, rate-limited, expired,
or slow to materialize. Repeated unbounded polling wastes API quota and can
leave an agent stuck fetching the same job over and over. The engine makes
each fetch cycle explicit and finite.

## Behavior

- Exact `owner/repository` and job ID inputs; no repository-wide log scraping.
- At most 3 attempts by default (hard maximum 5), with bounded exponential
  backoff and a 90-second overall deadline.
- A 404/410 is terminal for that cycle. It is reported as unavailable rather
  than retried or interpreted as an empty/successful log.
- 429, explicit rate-limit 403, 202, 5xx, and transport failures are retried
  only within the configured attempt/deadline budget.
- Download redirects are followed separately. The GitHub bearer token is sent
  only to api.github.com and is not forwarded to signed log-storage URLs.
- Responses are capped at 8 MiB by default (64 MiB hard maximum).
- Successful content is cached per repository/job ID for six hours within the
  workflow run. Cache entries are SHA-256 verified before reuse; corrupt or
  stale entries are fetched again.
- Unavailable/failed outcomes are negative-cached for the same period, so a
  second diagnostic branch cannot immediately repeat the same failed request.
- Cache state contains only a content digest and timestamp, never the token or
  log body. Cache files are created with owner-only permissions.
- Raw log content is stdout; cycle status and diagnostics are stderr.

## Resolver integration

`scripts/resolve-failures.sh` calls the engine through its shared
`get_job_logs` helper. The rate-limit detector, deterministic diagnostic path,
and AI-analysis path therefore consume the same cached log payload for a job
instead of each starting another download cycle.

## Invocation

The resolver supplies the state/cache paths and runtime token. For direct
diagnostics, set `GH_TOKEN` (or `GITHUB_TOKEN`) in the environment and run:

```sh
python3 scripts/log_fetch_cycle_engine.py \
  --repository Interested-Deving-1896/fork-sync-all \
  --job-id 123456789 \
  --state-file /tmp/fsa-log-fetch-state.json \
  --cache-dir /tmp/fsa-log-fetch-cache
```

Do not pass tokens on the command line, print signed URLs, upload raw logs as
artifacts, or put cache files in the repository workspace.

## Safety boundary

This engine only retrieves logs. It does not rerun jobs, redispatch workflows,
apply AI-generated fixes, commit changes, or merge pull requests. Those actions
remain separate and require their existing authorization and policy gates.
