#!/usr/bin/env bash
#
# Continuously monitors GitHub core rate limit quota and optionally dispatches
# a target workflow once quota recovers above a configurable threshold.
#
# On every poll iteration:
#   1. Fetch /rate_limit — core + graphql buckets.
#   2. Log remaining, limit, %, and ETA to reset.
#   3. Recalculate next sleep from the live reset_epoch:
#        sleep = clamp(reset_epoch - now + BUFFER_SEC, MIN_POLL_SEC, MAX_POLL_SEC)
#      This means the interval automatically tightens as the reset approaches
#      and widens if the reset slides (e.g. another workflow fires and resets
#      the window forward).
#   4. If remaining >= MIN_QUOTA and TARGET_WORKFLOW is set → dispatch and exit 0.
#   5. If remaining >= MIN_QUOTA and no target → exit 0 (monitor-only mode).
#   6. After TIMEOUT_MIN total minutes → exit 1.
#
# Required env vars:
#   GH_TOKEN          — token with repo + workflow scopes
#
# Optional env vars:
#   TARGET_WORKFLOW   — workflow filename to dispatch when quota recovers
#                       (omit for monitor-only mode)
#   TARGET_INPUTS     — JSON object of inputs for the target workflow (default: {})
#   TARGET_REF        — git ref to dispatch on (default: main)
#   GITHUB_OWNER      — default: Interested-Deving-1896
#   GITHUB_REPO       — default: fork-sync-all
#   MIN_QUOTA         — minimum core calls before dispatching (default: 2000)
#   BUFFER_SEC        — extra seconds after reset epoch before dispatching (default: 45)
#   MIN_POLL_SEC      — minimum sleep between polls (default: 30)
#   MAX_POLL_SEC      — maximum sleep between polls (default: 300)
#   TIMEOUT_MIN       — give up after this many minutes (default: 180)
#   DRY_RUN           — if "true", report without dispatching

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"

OWNER="${GITHUB_OWNER:-Interested-Deving-1896}"
REPO="${GITHUB_REPO:-fork-sync-all}"
TARGET_WORKFLOW="${TARGET_WORKFLOW:-}"
TARGET_INPUTS="${TARGET_INPUTS:-{}}"
TARGET_REF="${TARGET_REF:-main}"
MIN_QUOTA="${MIN_QUOTA:-2000}"
BUFFER_SEC="${BUFFER_SEC:-45}"
MIN_POLL_SEC="${MIN_POLL_SEC:-30}"
MAX_POLL_SEC="${MAX_POLL_SEC:-300}"
TIMEOUT_MIN="${TIMEOUT_MIN:-180}"
DRY_RUN="${DRY_RUN:-false}"

GH_API="https://api.github.com"
SUMMARY_FILE="${GITHUB_STEP_SUMMARY:-}"

ts()    { date -u '+%H:%M:%S UTC'; }
info()  { echo "[quota-monitor] $(ts)  $*"; }
warn()  { echo "[quota-monitor] $(ts) ⚠️  $*" >&2; }

summary_append() {
  [[ -n "$SUMMARY_FILE" ]] && echo "$1" >> "$SUMMARY_FILE"
}

# ── Rate limit fetch ──────────────────────────────────────────────────────────
# Outputs one line per bucket: "<name> <remaining> <limit> <reset_epoch>"

fetch_all_quotas() {
  local raw
  raw=$(curl -sf \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${GH_API}/rate_limit" 2>/dev/null) || { warn "rate_limit fetch failed"; return 1; }

  python3 -c "
import sys, json
d = json.loads(sys.argv[1])
for name, info in sorted(d.get('resources', {}).items()):
    print(name, info.get('remaining', 0), info.get('limit', 0), info.get('reset', 0))
" "$raw"
}

# Extract a single bucket's values from fetch_all_quotas output
# Usage: get_bucket <lines> <bucket_name>  → "<remaining> <limit> <reset_epoch>"
get_bucket() {
  echo "$1" | awk -v name="$2" '$1 == name { print $2, $3, $4 }'
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

dispatch_workflow() {
  local payload
  payload=$(python3 -c "
import sys, json
ref    = sys.argv[1]
inputs = json.loads(sys.argv[2])
print(json.dumps({'ref': ref, 'inputs': inputs}))
" "$TARGET_REF" "$TARGET_INPUTS")

  curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "${GH_API}/repos/${OWNER}/${REPO}/actions/workflows/${TARGET_WORKFLOW}/dispatches"
}

# ── Summary helpers ───────────────────────────────────────────────────────────

format_reset() {
  local epoch="$1"
  python3 -c "
from datetime import datetime, timezone
print(datetime.fromtimestamp(${epoch}, tz=timezone.utc).strftime('%H:%M:%S UTC'))
" 2>/dev/null || echo "${epoch}"
}

format_eta() {
  local secs="$1"
  if [[ "$secs" -le 0 ]]; then echo "now"
  elif [[ "$secs" -lt 60 ]]; then echo "${secs}s"
  else echo "$(( secs / 60 ))m$(( secs % 60 ))s"
  fi
}

# ── Main loop ─────────────────────────────────────────────────────────────────

START_EPOCH=$(date +%s)
TIMEOUT_SEC=$(( TIMEOUT_MIN * 60 ))
DEADLINE=$(( START_EPOCH + TIMEOUT_SEC ))

info "GitHub quota monitor starting"
info "  min_quota=${MIN_QUOTA}  buffer=${BUFFER_SEC}s  poll=${MIN_POLL_SEC}–${MAX_POLL_SEC}s  timeout=${TIMEOUT_MIN}m"
[[ -n "$TARGET_WORKFLOW" ]] && info "  target=${OWNER}/${REPO} → ${TARGET_WORKFLOW}  ref=${TARGET_REF}"
[[ -n "$TARGET_WORKFLOW" ]] && info "  inputs=${TARGET_INPUTS}"
info ""

summary_append "## Quota Monitor"
summary_append ""
[[ -n "$TARGET_WORKFLOW" ]] && summary_append "> Target: \`${TARGET_WORKFLOW}\` on \`${TARGET_REF}\` — dispatches when core quota ≥ **${MIN_QUOTA}**"
summary_append ""
summary_append "| Poll | Time (UTC) | Core | GraphQL | Core Reset ETA | Next Poll |"
summary_append "|---|---|---|---|---|---|"

attempt=0
while true; do
  (( attempt++ )) || true
  NOW=$(date +%s)

  # Timeout guard
  if [[ "$NOW" -ge "$DEADLINE" ]]; then
    warn "Timed out after ${TIMEOUT_MIN}m."
    summary_append ""
    summary_append "> ❌ Timed out after ${TIMEOUT_MIN}m without reaching quota threshold."
    exit 1
  fi

  # Fetch all buckets
  all_quotas=$(fetch_all_quotas) || { sleep 30; continue; }

  # Parse core + graphql
  read -r core_rem core_lim core_reset < <(get_bucket "$all_quotas" "core")
  read -r gql_rem  gql_lim  _          < <(get_bucket "$all_quotas" "graphql")

  core_rem="${core_rem:-0}"; core_lim="${core_lim:-5000}"; core_reset="${core_reset:-0}"
  gql_rem="${gql_rem:-0}";   gql_lim="${gql_lim:-5000}"

  # Compute ETA and adaptive sleep
  reset_in=$(( core_reset - NOW ))
  reset_str=$(format_reset "$core_reset")
  eta_str=$(format_eta "$reset_in")

  if [[ "$reset_in" -gt 0 ]]; then
    raw_sleep=$(( reset_in + BUFFER_SEC ))
  else
    raw_sleep="$MIN_POLL_SEC"
  fi
  sleep_sec=$(( raw_sleep < MIN_POLL_SEC ? MIN_POLL_SEC : raw_sleep ))
  sleep_sec=$(( sleep_sec > MAX_POLL_SEC ? MAX_POLL_SEC : sleep_sec ))

  core_pct=$(( core_lim > 0 ? core_rem * 100 / core_lim : 0 ))
  gql_pct=$(( gql_lim  > 0 ? gql_rem  * 100 / gql_lim  : 0 ))

  info "#${attempt}  core=${core_rem}/${core_lim} (${core_pct}%)  graphql=${gql_rem}/${gql_lim} (${gql_pct}%)  reset_eta=${eta_str}  next_poll=${sleep_sec}s"
  summary_append "| #${attempt} | $(ts) | ${core_rem}/${core_lim} (${core_pct}%) | ${gql_rem}/${gql_lim} (${gql_pct}%) | ${eta_str} (${reset_str}) | ${sleep_sec}s |"

  # Check if quota is sufficient
  if [[ "$core_rem" -ge "$MIN_QUOTA" ]]; then
    if [[ -z "$TARGET_WORKFLOW" ]]; then
      info "Quota sufficient (${core_rem} >= ${MIN_QUOTA}) — monitor-only mode, exiting."
      summary_append ""
      summary_append "> ✅ Core quota recovered to **${core_rem}** after ${attempt} poll(s). No target workflow configured."
      exit 0
    fi

    info "Quota sufficient (${core_rem} >= ${MIN_QUOTA}) — dispatching ${TARGET_WORKFLOW}..."

    if [[ "$DRY_RUN" == "true" ]]; then
      info "DRY RUN — would dispatch ${TARGET_WORKFLOW} with inputs: ${TARGET_INPUTS}"
      summary_append ""
      summary_append "> 🔍 Dry run — dispatch skipped. Would have triggered \`${TARGET_WORKFLOW}\` with quota at **${core_rem}**."
      exit 0
    fi

    http_status=$(dispatch_workflow)

    if [[ "$http_status" == "204" ]]; then
      info "✅ Dispatched ${TARGET_WORKFLOW} (HTTP 204) — quota at dispatch: ${core_rem}"
      summary_append ""
      summary_append "> ✅ Dispatched \`${TARGET_WORKFLOW}\` after ${attempt} poll(s). Core quota at dispatch: **${core_rem}**."
      exit 0
    else
      warn "Dispatch returned HTTP ${http_status} — will retry next poll"
      summary_append ""
      summary_append "> ⚠️  Dispatch attempt #${attempt} returned HTTP ${http_status} — retrying in ${sleep_sec}s."
    fi
  fi

  info "  -> sleeping ${sleep_sec}s (core reset in ${eta_str})"
  sleep "$sleep_sec"
done
