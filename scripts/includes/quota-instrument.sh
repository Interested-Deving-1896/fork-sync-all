#!/usr/bin/env bash
# scripts/includes/quota-instrument.sh — REST quota consumption instrumentation
#
# Records the REST calls consumed by a workflow run by sampling quota
# remaining before and after the main work. The delta is written to the
# GitHub Actions step summary in a structured format that
# update-quota-costs.yml can parse to compute observed p50/p95 values.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/includes/quota-instrument.sh"
#
#   # At the start of the main job step (after checkout, before work):
#   qi_begin
#
#   # ... do work ...
#
#   # At the end of the main job step (after all work is done):
#   qi_end
#
# Environment (all optional — defaults work for standard workflows):
#   QI_WORKFLOW_NAME  — workflow display name (default: $GITHUB_WORKFLOW)
#   QI_RUN_ID         — run ID (default: $GITHUB_RUN_ID)
#   GH_TOKEN          — PAT for rate_limit check (default: $GH_TOKEN or $SYNC_TOKEN)
#   QI_DISABLED       — set to "true" to skip instrumentation entirely
#
# Output format written to GITHUB_STEP_SUMMARY:
#   <!-- quota-instrument: {"workflow":"...","run_id":...,"before":...,"after":...,"delta":...,"ts":"..."} -->
#
# The HTML comment format is intentional — it's invisible in the rendered
# summary but parseable by update-quota-costs.yml via grep + jq.
#
# Guard against double-sourcing
[[ -n "${_QI_LOADED:-}" ]] && return 0
_QI_LOADED=1

_QI_BEFORE=0
_QI_TOKEN="${GH_TOKEN:-${SYNC_TOKEN:-}}"
_QI_API="https://api.github.com"

_qi_remaining() {
  if [[ -z "$_QI_TOKEN" ]]; then
    echo "0"
    return
  fi
  curl -sf \
    -H "Authorization: token ${_QI_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${_QI_API}/rate_limit" \
    2>/dev/null \
    | python3 -c "
import sys, json
try:
    print(json.load(sys.stdin)['resources']['core']['remaining'])
except Exception:
    print(0)
" 2>/dev/null || echo "0"
}

# qi_begin — sample quota before work starts. Call once at the start of the
# main job step, after checkout but before any API-consuming work.
qi_begin() {
  [[ "${QI_DISABLED:-false}" == "true" ]] && return 0
  _QI_BEFORE=$(_qi_remaining)
  echo "[quota-instrument] before=${_QI_BEFORE}" >&2
}

# qi_end — sample quota after work completes and write the delta to the
# step summary. Call once at the end of the main job step.
qi_end() {
  [[ "${QI_DISABLED:-false}" == "true" ]] && return 0
  local after
  after=$(_qi_remaining)
  local delta=$(( _QI_BEFORE - after ))
  local workflow="${QI_WORKFLOW_NAME:-${GITHUB_WORKFLOW:-unknown}}"
  local run_id="${QI_RUN_ID:-${GITHUB_RUN_ID:-0}}"
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  echo "[quota-instrument] after=${after} delta=${delta}" >&2

  # Write structured record to step summary (invisible HTML comment)
  local summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
  python3 -c "
import json, sys
record = {
    'workflow': sys.argv[1],
    'run_id':   int(sys.argv[2]),
    'before':   int(sys.argv[3]),
    'after':    int(sys.argv[4]),
    'delta':    int(sys.argv[5]),
    'ts':       sys.argv[6],
}
print('<!-- quota-instrument: ' + json.dumps(record, separators=(',',':')) + ' -->')
" "$workflow" "$run_id" "$_QI_BEFORE" "$after" "$delta" "$ts" \
  >> "$summary" 2>/dev/null || true
}
