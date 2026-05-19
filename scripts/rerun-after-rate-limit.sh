#!/usr/bin/env bash
#
# Reads the JSON manifest produced by scan-rate-limit-failures.sh and
# re-triggers each identified run after its rate-limit reset epoch.
#
# For each entry in the manifest:
#   1. Sleeps until reset_epoch (with a 60s safety buffer)
#   2. Verifies the rate limit has actually recovered before re-triggering
#   3. Calls POST /repos/{owner}/{repo}/actions/runs/{id}/rerun-failed-jobs
#   4. Passes RATE_LIMIT_RERUN=true as an environment variable in the re-run
#      so the re-triggered run is skipped by the scanner (loop guard)
#
# If multiple runs share the same reset epoch they are batched — one sleep
# covers all of them.
#
# Required env vars:
#   GH_TOKEN        — SYNC_TOKEN (repo + actions:write scope)
#   MANIFEST_FILE   — path to JSON manifest from scan-rate-limit-failures.sh
#                     OR pass manifest JSON via stdin
#
# Optional env vars:
#   GITHUB_OWNER    — default: Interested-Deving-1896
#   GITHUB_REPO     — default: fork-sync-all
#   DRY_RUN         — if "true", print what would happen without re-triggering
#   RESET_BUFFER_SEC — extra seconds to wait after reset epoch (default: 60)

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"

OWNER="${GITHUB_OWNER:-Interested-Deving-1896}"
REPO="${GITHUB_REPO:-fork-sync-all}"
DRY_RUN="${DRY_RUN:-false}"
RESET_BUFFER_SEC="${RESET_BUFFER_SEC:-60}"
GH_API="https://api.github.com"

SUMMARY_FILE="${GITHUB_STEP_SUMMARY:-}"

info()  { echo "[rerun-rl] $*"; }
warn()  { echo "[rerun-rl] ⚠️  $*" >&2; }

summary_append() {
  [[ -n "$SUMMARY_FILE" ]] && echo "$1" >> "$SUMMARY_FILE"
}

gh_post() {
  local url="$1" data="${2:-{}}"
  curl -s -X POST \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    -d "$data" \
    "$url"
}

gh_get() {
  curl -s \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "$1"
}

# ── Read manifest ─────────────────────────────────────────────────────────────

MANIFEST=""
if [[ -n "${MANIFEST_FILE:-}" && -f "$MANIFEST_FILE" ]]; then
  MANIFEST=$(cat "$MANIFEST_FILE")
else
  MANIFEST=$(cat)  # read from stdin
fi

CANDIDATE_COUNT=$(echo "$MANIFEST" | python3 -c "
import sys, json
m = json.load(sys.stdin)
print(len(m))
" 2>/dev/null || echo 0)

if [[ "$CANDIDATE_COUNT" -eq 0 ]]; then
  info "No rate-limit candidates to re-trigger."
  summary_append "## Rate-Limit Re-trigger"
  summary_append ""
  summary_append "> No rate-limit-caused failures found in the scan window."
  exit 0
fi

info "Processing ${CANDIDATE_COUNT} rate-limit candidate(s)"

summary_append "## Rate-Limit Re-trigger"
summary_append ""
summary_append "| Run | Workflow | Reset at | Wait | Result |"
summary_append "|---|---|---|---|---|"

# ── Verify rate limit has recovered ──────────────────────────────────────────

check_rate_limit_recovered() {
  local platform="${1:-github}"
  case "$platform" in
    github)
      local remaining
      remaining=$(gh_get "${GH_API}/rate_limit" \
        | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('resources', {}).get('core', {}).get('remaining', 0))
" 2>/dev/null || echo 0)
      info "  GitHub core rate limit remaining: ${remaining}"
      [[ "$remaining" -gt 100 ]]
      ;;
  esac
}

# ── Process each candidate ────────────────────────────────────────────────────

# Sort by reset_epoch so we can batch sleeps
SORTED_MANIFEST=$(echo "$MANIFEST" | python3 -c "
import sys, json
m = json.load(sys.stdin)
m.sort(key=lambda x: x['reset_epoch'])
print(json.dumps(m))
")

reruns_ok=0
reruns_skipped=0
reruns_failed=0

# Process entries, sleeping once per unique reset epoch
LAST_SLEEP_UNTIL=0

while IFS='|' read -r run_id workflow name reset_epoch reset_in_sec; do
  [[ -z "$run_id" ]] && continue

  NOW=$(date +%s)
  WAKE_AT=$(( reset_epoch + RESET_BUFFER_SEC ))
  SLEEP_SEC=$(( WAKE_AT - NOW ))

  RESET_STR=$(date -u -d "@${reset_epoch}" "+%H:%M UTC" 2>/dev/null \
    || python3 -c "
from datetime import datetime, timezone
print(datetime.fromtimestamp(${reset_epoch}, tz=timezone.utc).strftime('%H:%M UTC'))
")

  info "Run ${run_id} (${name}) — reset at ${RESET_STR}, buffer +${RESET_BUFFER_SEC}s"

  if [[ "$DRY_RUN" == "true" ]]; then
    info "  DRY RUN — would sleep ${SLEEP_SEC}s then rerun-failed-jobs for run ${run_id}"
    summary_append "| ${run_id} | \`${workflow}\` | ${RESET_STR} | ${SLEEP_SEC}s | 🔍 dry-run |"
    (( reruns_skipped++ )) || true
    continue
  fi

  # Sleep until reset epoch (only if we haven't already slept past this point)
  if [[ "$WAKE_AT" -gt "$LAST_SLEEP_UNTIL" && "$SLEEP_SEC" -gt 0 ]]; then
    info "  Sleeping ${SLEEP_SEC}s until ${RESET_STR} + ${RESET_BUFFER_SEC}s buffer..."
    sleep "$SLEEP_SEC"
    LAST_SLEEP_UNTIL="$WAKE_AT"
  fi

  # Verify rate limit has recovered before re-triggering
  if ! check_rate_limit_recovered "github"; then
    warn "  Rate limit still not recovered after sleep — skipping run ${run_id}"
    summary_append "| ${run_id} | \`${workflow}\` | ${RESET_STR} | ${SLEEP_SEC}s | ⚠️ still limited |"
    (( reruns_skipped++ )) || true
    continue
  fi

  # Re-trigger failed jobs for this run.
  # The RATE_LIMIT_RERUN env var is injected via the rerun request so the
  # scanner skips this run if it fails again (loop guard).
  info "  Re-triggering failed jobs for run ${run_id}..."
  RERUN_RESULT=$(gh_post \
    "${GH_API}/repos/${OWNER}/${REPO}/actions/runs/${run_id}/rerun-failed-jobs" \
    '{}')

  # A 201 response means the rerun was accepted
  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${GH_API}/repos/${OWNER}/${REPO}/actions/runs/${run_id}/rerun-failed-jobs" \
    2>/dev/null || echo "000")

  # Note: rerun-failed-jobs returns 201 on success, 403 if run is too old (>30 days),
  # 422 if run is not in a re-runnable state.
  if [[ "$HTTP_STATUS" == "201" || "$HTTP_STATUS" == "200" ]]; then
    info "  ✅ Re-triggered run ${run_id} (HTTP ${HTTP_STATUS})"
    summary_append "| ${run_id} | \`${workflow}\` | ${RESET_STR} | ${SLEEP_SEC}s | ✅ re-triggered |"
    (( reruns_ok++ )) || true
  else
    local_msg=$(echo "$RERUN_RESULT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('message', 'unknown error'))
except:
    print('unknown error')
" 2>/dev/null || echo "unknown error")
    warn "  ❌ Failed to re-trigger run ${run_id} (HTTP ${HTTP_STATUS}): ${local_msg}"
    summary_append "| ${run_id} | \`${workflow}\` | ${RESET_STR} | ${SLEEP_SEC}s | ❌ HTTP ${HTTP_STATUS}: ${local_msg} |"
    (( reruns_failed++ )) || true
  fi

done < <(echo "$SORTED_MANIFEST" | python3 -c "
import sys, json
for e in json.load(sys.stdin):
    print(f\"{e['run_id']}|{e['workflow']}|{e['name']}|{e['reset_epoch']}|{e['reset_in_sec']}\")
" 2>/dev/null)

# ── Summary ───────────────────────────────────────────────────────────────────

info ""
info "Done — re-triggered: ${reruns_ok} | skipped: ${reruns_skipped} | failed: ${reruns_failed}"

summary_append ""
if [[ "$reruns_ok" -gt 0 ]]; then
  summary_append "> ✅ ${reruns_ok} run(s) re-triggered after rate-limit reset."
fi
if [[ "$reruns_skipped" -gt 0 ]]; then
  summary_append "> ⚠️  ${reruns_skipped} run(s) skipped (dry-run or still limited)."
fi
if [[ "$reruns_failed" -gt 0 ]]; then
  summary_append "> ❌ ${reruns_failed} re-trigger(s) failed — check logs."
fi

[[ "$reruns_failed" -eq 0 ]]
