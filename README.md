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

2. Create a GitHub Personal Access Token (classic) with `public_repo` scope:
   - Go to **Settings > Developer settings > Personal access tokens > Tokens (classic)**
   - Click **Generate new token (classic)**
   - Select the `public_repo` scope
   - Copy the token

3. Add the token as a repository secret:
   - Go to this repo's **Settings > Secrets and variables > Actions**
   - Click **New repository secret**
   - Name: `SYNC_TOKEN`
   - Value: paste your PAT

4. The workflow runs automatically on schedule. To trigger manually:
   - Go to **Actions > Sync All Forks > Run workflow**

## Rate limits

GitHub allows 5,000 API requests per hour for authenticated users. With ~2,700 forks,
a full sync uses roughly 2,700–5,000 requests depending on branch counts. The script
includes rate-limit detection and will pause/resume automatically if the limit is hit.

## Merge conflicts

If a fork branch has diverged from upstream (local commits exist), the sync for that
branch will fail gracefully. These are logged as warnings so you can resolve them manually.
