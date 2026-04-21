# fork-sync-all

A GitHub Actions workflow that syncs all forked repositories in your account with their upstream sources daily.

## What it does

- Runs daily at 06:00 UTC (configurable)
- Lists all forks in your GitHub account (handles pagination for large accounts)
- Syncs every branch that tracks an upstream branch, not just the default branch
- Handles GitHub API rate limits with automatic backoff
- Logs successes and failures per repo/branch

## Setup

1. Push this repository to your GitHub account.
2. Create a GitHub Personal Access Token (classic) with `public_repo` and `models:read` scopes:
   - Go to **Settings > Developer settings > Personal access tokens > Tokens (classic)**
   - Click **Generate new token (classic)**
   - Select the `public_repo` scope (for repo access)
   - Select the `models:read` scope (for AI failure resolver)
   - Copy the token
3. Add the token as a repository secret:
   - Go to this repo's **Settings > Secrets and variables > Actions**
   - Click **New repository secret**
   - Name: `SYNC_TOKEN`
   - Value: paste your PAT
4. The workflow runs automatically on schedule. To trigger manually:
   - Go to **Actions > Sync All Forks > Run workflow**

## Rate limits

GitHub allows 5,000 API requests per hour for authenticated users. With ~2,700 forks, a full sync uses roughly 2,700–5,000 requests depending on branch counts. The script includes rate-limit detection and will pause/resume automatically if the limit is hit.

## pieroproietti Fork Sync (hourly)

A dedicated workflow (`sync-pieroproietti-forks.yml`) runs **every hour at :05 past the hour** and syncs only the forks whose upstream owner is `pieroproietti`. This gives near-real-time tracking of that upstream without waiting for the daily full-account sync.

- Filters forks by `parent.owner.login == "pieroproietti"` via the GitHub API
- Syncs the default branch of each matching fork via `merge-upstream`
- Self-limits at 50 minutes to exit cleanly before the 60-minute job timeout
- Uses the same `SYNC_TOKEN` secret — no additional setup required

To trigger manually: **Actions > Sync pieroproietti Forks > Run workflow**

The daily `sync-forks.yml` still covers all forks (including pieroproietti ones) at 06:00 UTC. The hourly job is additive — it only targets the pieroproietti subset.

## CI Failure Resolver

A second workflow (`resolve-failures.yml`) runs daily at 07:30 UTC and:

1. Scans all repos across `openos-project`, `openos-project`, and `OpenOS-Project-Ecosystem-OOC`
2. Finds failed workflow runs
3. Fetches job logs and the workflow YAML file
4. Sends them to GitHub Models (GPT-4o-mini) for analysis
5. Auto-commits fixes when the AI produces a valid correction

To trigger manually: **Actions > Resolve CI Failures > Run workflow**

The `SYNC_TOKEN` PAT needs `models:read` scope for AI access.

## Merge conflicts

If a fork branch has diverged from upstream (local commits exist), the sync for that branch will fail gracefully. These are logged as warnings so you can resolve them manually.
