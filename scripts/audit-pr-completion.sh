#!/usr/bin/env bash
# Read-only audit of open pull requests and their completion signals.
set -euo pipefail
REPO="${1:-${GITHUB_REPOSITORY:-}}"
STALE_DAYS="${2:-14}"
if [[ -z "$REPO" || ! "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then echo "usage: $0 owner/repository [stale-days]" >&2; exit 2; fi
if [[ ! "$STALE_DAYS" =~ ^[0-9]+$ ]]; then echo "stale-days must be a non-negative integer" >&2; exit 2; fi
command -v gh >/dev/null || { echo "error: gh CLI is required" >&2; exit 2; }
command -v jq >/dev/null || { echo "error: jq is required" >&2; exit 2; }
gh auth status >/dev/null
now=$(date -u +%s)
printf 'Repository: %s\nChecked (UTC): %s\nOpen PR stale threshold: %s days\n\n' "$REPO" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$STALE_DAYS"
printf 'PR\tSTATE\tDRAFT\tCHECKS\tREVIEW\tUPDATED\tFLAGS\tTITLE\tURL\n'
gh pr list --repo "$REPO" --state open --limit 500 --json number,title,isDraft,updatedAt,url,reviewDecision,statusCheckRollup,mergeStateStatus | jq -r '.[] | [.number, .title, .isDraft, .updatedAt, .url, (.reviewDecision // "REVIEW_UNKNOWN"), (.mergeStateStatus // "MERGE_STATE_UNKNOWN"), ([.statusCheckRollup[]? | .conclusion // .state // .status // "UNKNOWN"] | join(","))] | @tsv' |
while IFS=$'\t' read -r number title draft updated url review merge_state check_states; do
  updated_epoch=$(date -u -d "$updated" +%s 2>/dev/null || echo 0); age_days=0
  if (( updated_epoch > 0 )); then age_days=$(((now - updated_epoch) / 86400)); fi
  flags=""
  add_flag() { if [[ -n "$flags" ]]; then flags+=","; fi; flags+="$1"; }
  if [[ "$draft" == "true" ]]; then add_flag "DRAFT_NEEDS_HUMAN_REVIEW"; fi
  if (( updated_epoch == 0 )); then add_flag "UPDATE_DATE_UNKNOWN"; elif (( age_days >= STALE_DAYS )); then add_flag "STALE_${age_days}D"; fi
  if [[ -z "$check_states" ]]; then add_flag "CHECKS_UNKNOWN_OR_NONE"
  elif grep -Eqi 'failure|timed_out|cancelled|action_required' <<<"$check_states"; then add_flag "CHECK_FAILURE_OR_ACTION_REQUIRED"
  elif grep -Eqi 'pending|in_progress|queued|waiting|requested' <<<"$check_states"; then add_flag "CHECKS_INCOMPLETE"
  elif grep -Eqi 'skipped' <<<"$check_states"; then add_flag "CHECKS_PASSED_WITH_SKIPS"
  elif grep -Eqi 'success' <<<"$check_states"; then add_flag "CHECKS_SUCCESS_REPORTED"
  else add_flag "CHECK_STATE_UNCLASSIFIED"; fi
  if [[ "$review" == "CHANGES_REQUESTED" ]]; then add_flag "CHANGES_REQUESTED"; fi
  if [[ "$merge_state" == "BLOCKED" || "$merge_state" == "DIRTY" ]]; then add_flag "MERGE_BLOCKED_OR_CONFLICT"; fi
  if [[ -z "$flags" ]]; then flags="NO_OBVIOUS_FLAGS"; fi
  printf '%s\tOPEN\t%s\t%s\t%s\t%s (%sd)\t%s\t%s\t%s\n' "$number" "$draft" "${check_states:-none}" "$review" "$updated" "$age_days" "$flags" "$title" "$url"
done
cat <<'NOTE'

Interpretation:
- This is a triage report, not an automatic declaration that work is complete.
- Draft PRs need an explicit human decision before being marked ready.
- Skipped checks are reported separately; they are not treated as successful builds.
- Check state, review decision, and merge state are snapshots and may change immediately.
- This script is read-only: it does not edit PRs, merge, dispatch workflows, or change repository settings.
NOTE
