# Forge Capacity Governor

Fork-Sync-All treats hosted-runner capacity as a shared forge resource. The
governor prevents central dispatchers and managed consumer fallbacks from
competing blindly for the same runner pool.

## Control flow

1. Managed consumer workflows use a job-level `FSA_MANAGED` guard, so redundant
   schedules are skipped before GitHub assigns a runner.
2. `forge-capacity-observe.py` reads the GitHub organization Actions stream, or
   the managed-repository registry for a personal account, and counts jobs that
   have a real `runner_id`. Old `in_progress` run records with no active jobs
   are excluded.
3. `forge-capacity-manager.py` normalizes the observation, reserves emergency
   slots, and returns an admission decision for priority tiers 1 through 4.
4. `dispatch-and-wait.sh` waits for admission before creating a child workflow
   run. Existing runs are adopted without another admission charge.

GitHub exposes organization work but no personal-account-wide hosted-runner
capacity endpoint. The personal-account fallback scans the 81 managed entries
in `config/template-consumers.yml`, so it uses `low` confidence and does not
claim visibility into unrelated repositories. `runner-status.yml` publishes
this bounded snapshot to `FORGE_CAPACITY_GITHUB` every 30 minutes; dispatchers
only rescan during stale/full recovery. `config/forge-capacity.yml` defaults to
20 standard jobs and reserves three slots from non-critical work. Change that
ceiling when the account plan or runner arrangement changes.

## Other forges

`scripts/includes/platform-adapter.sh` exposes the same normalized contract for
GitLab, Gitea, Forgejo, and Codeberg. A deployment may provide:

- `PA_CAPACITY_LIMIT`, `PA_CAPACITY_RUNNING`, and `PA_CAPACITY_QUEUED`;
- `PA_CAPACITY_STATUS_URL` for an authenticated deployment-specific endpoint;
- `PA_CAPACITY_GITLAB_RUNNER_IDS` to count active GitLab runner jobs.

Unknown values stay unknown. The governor fails closed for ordinary work while
allowing explicitly critical work to use the configured emergency policy.

## Dispatcher controls

- `DISPATCH_PRIORITY=1..4` selects the policy tier.
- `DISPATCH_CAPACITY_WAIT` controls how long a dispatch waits for a slot.
- `FORGE_CAPACITY_REQUIRED=true` fails closed if an observation cannot be made.
- `FORGE_CAPACITY_ENABLED=false` is the emergency bypass.
- `DISPATCH_NO_WAIT=true` keeps admission and exact-run correlation but returns
  as soon as the run is accepted.

Flush and critical-deploy paths use priority 1. Other dispatches default to
priority 2. A deferred admission exits with code 3 after its wait budget.

## Rollout and recovery

After changing managed-mode guards, run `sync-template.yml` once with
`mode=propagate`. This force-refreshes only the explicitly listed guard files;
consumer-owned files still retain the normal `FORCE=false` protection.

If the pool is already saturated, cancel only confirmed stale jobs with an
assigned runner. A queued job with `runner_id: 0` consumes no runner and should
normally be left for the governor or GitHub scheduler to admit.
