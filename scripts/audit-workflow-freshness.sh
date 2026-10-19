#!/usr/bin/env bash
# audit-workflow-freshness.sh — read-only Actions workflow activity diagnostic.
#
# Compares each enabled workflow's newest run returned by the GitHub Actions API.
# This does not emulate or diagnose GitHub Android's native Workflows screen; it
# provides reproducible evidence to distinguish missing run history from UI staleness.
#
# Usage:
#   scripts/audit-workflow-freshness.sh [owner/repository] [stale-days]
#
# Requirements: gh, jq; authenticated gh session with read access to Actions.
# No workflow is dispatched and no repository state is changed.

set -euo pipefail

REPO="${1:-${GITHUB_REPOSITORY:-}}"
STALE_DAYS="${2:-30}"

if [[ -z "$REPO" ]]; then
  echo "usage: $0 owner/repository [stale-days]" >&2
  exit 2
fi
if [[ ! "$STALE_DAYS" =~ ^[0-9]+$ ]]; then
  echo "stale-days must be a non-negative integer" >&2
  exit 2
fi
if [[ ! "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "error: repository must be in owner/name form" >&2
  exit 2
fi
command -v gh >/dev/null 2>&1 || { echo "error: gh CLI is required" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }
gh auth status >/dev/null

# GNU date uses -d; BSD/macOS date uses -j -f. Support both.
parse_epoch() {
  local timestamp="$1"
  date -u -d "$timestamp" +%s 2>/dev/null && return 0
  date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$timestamp" +%s 2>/dev/null
}

now_epoch=$(date -u +%s)
cutoff_epoch=$((now_epoch - STALE_DAYS * 86400))

printf 'Repository: %s\nStale threshold: %s days\n' "$REPO" "$STALE_DAYS"
printf 'Checked at (UTC): %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'STATE\tLAST RUN (UTC)\tWORKFLOW\tFILE\tRUN URL\n'

workflows=$(gh api --paginate "repos/$REPO/actions/workflows?per_page=100" --jq '.workflows[] | select(.state == "active") | [.id, .name, .path] | @tsv')
if [[ -z "$workflows" ]]; then
  echo "No active workflows returned by the API (or no workflows are visible)." >&2
  exit 1
fi

while IFS=$'\t' read -r id name path; do
  [[ -n "$id" ]] || continue
  run=$(gh api "repos/$REPO/actions/workflows/$id/runs?per_page=1" --jq '.workflow_runs[0] // empty')
  if [[ -z "$run" ]]; then
    printf 'NO_RUN\t-\t%s\t%s\t-\n' "$name" "$path"
    continue
  fi
  created=$(jq -r '.created_at' <<<"$run")
  created_epoch=$(parse_epoch "$created" 2>/dev/null || echo 0)
  url=$(jq -r '.html_url' <<<"$run")
  if (( created_epoch == 0 )); then
    state="DATE_UNKNOWN"
  elif (( created_epoch < cutoff_epoch )); then
    state="STALE"
  else
    state="RECENT"
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$state" "$created" "$name" "$path" "$url"
done <<<"$workflows"
