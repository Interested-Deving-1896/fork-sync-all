#!/usr/bin/env bash
#
# Monitors GitHub rate limit quota and workflow run state.
#
# Two modes, selected by MODE env var:
#
#   quota  (default) — poll /rate_limit; dispatch TARGET_WORKFLOW when core
#                      quota recovers above MIN_QUOTA. Omit TARGET_WORKFLOW
#                      for monitor-only (log and exit when quota recovers).
#
#   watch            — poll /actions/runs for WATCH_WORKFLOW until it reaches
#                      a target status (in_progress or completed). Useful for
#                      "tell me when sync-template actually starts running"
#                      without burning a runner on a long sleep.
#
# Quota mode — poll algorithm:
#   1. Fetch /rate_limit — core + graphql buckets.
#   2. Log remaining, limit, %, and ETA to reset.
#   3. Recalculate next sleep from the live reset_epoch:
#        sleep = clamp(reset_epoch - now + BUFFER_SEC, MIN_POLL_SEC, MAX_POLL_SEC)
#      Interval tightens as reset approaches; widens if reset slides.
#   4. If remaining >= MIN_QUOTA and TARGET_WORKFLOW set → dispatch and exit 0.
#   5. If remaining >= MIN_QUOTA and no target → exit 0 (monitor-only).
#   6. After TIMEOUT_MIN minutes → exit 1.
#
# Watch mode — poll algorithm:
#   1. Fetch the most recent run of WATCH_WORKFLOW.
#   2. Log run ID, status, conclusion, and elapsed time.
#   3. Sleep WATCH_POLL_SEC seconds (recalculated from run age — tighter when
#      the run is young, wider when it has been running a long time).
#   4. Exit 0 when status matches WATCH_UNTIL (default: completed).
#   5. After TIMEOUT_MIN minutes → exit 1.
#
# Required env vars:
#   GH_TOKEN          — token with repo + workflow scopes
#
# Optional env vars (quota mode):
#   TARGET_WORKFLOW   — workflow filename to dispatch when quota recovers
#   TARGET_INPUTS     — JSON object of inputs for the target workflow (default: {})
#   TARGET_REF        — git ref to dispatch on (default: main)
#   MIN_QUOTA         — minimum core calls before dispatching (default: 2000)
#   BUFFER_SEC        — extra seconds after reset epoch (default: 45)
#   MIN_POLL_SEC      — minimum sleep between polls (default: 30)
#   MAX_POLL_SEC      — maximum sleep between polls (default: 300)
#
# Optional env vars (watch mode):
#   WATCH_WORKFLOW        — workflow filename to watch (e.g. sync-template.yml)
#   WATCH_UNTIL           — target status: in_progress | completed (default: completed)
#   WATCH_TIMEOUT_MIN     — expected max runtime of the watched workflow in minutes
#                           used to derive adaptive poll interval (default: 60)
#                           poll = clamp(run_age / WATCH_TIMEOUT_MIN * MAX_POLL_SEC,
#                                        MIN_POLL_SEC, MAX_POLL_SEC)
#                           i.e. polls are tight at the start and widen as the run ages
#
# Shared optional env vars:
#   GITHUB_OWNER      — default: Interested-Deving-1896
#   GITHUB_REPO       — default: fork-sync-all
#   TIMEOUT_MIN       — give up after this many minutes (default: 180)
#   DRY_RUN           — if "true", report without dispatching (quota mode only)

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"

MODE="${MODE:-quota}"
OWNER="${GITHUB_OWNER:-Interested-Deving-1896}"
REPO="${GITHUB_REPO:-fork-sync-all}"
TIMEOUT_MIN="${TIMEOUT_MIN:-180}"
DRY_RUN="${DRY_RUN:-false}"

# quota mode
TARGET_WORKFLOW="${TARGET_WORKFLOW:-}"
TARGET_INPUTS="${TARGET_INPUTS:-{}}"
TARGET_REF="${TARGET_REF:-main}"
MIN_QUOTA="${MIN_QUOTA:-2000}"
BUFFER_SEC="${BUFFER_SEC:-45}"
MIN_POLL_SEC="${MIN_POLL_SEC:-30}"
MAX_POLL_SEC="${MAX_POLL_SEC:-300}"

# watch mode
WATCH_WORKFLOW="${WATCH_WORKFLOW:-}"
WATCH_UNTIL="${WATCH_UNTIL:-completed}"     # in_progress | completed
WATCH_TIMEOUT_MIN="${WATCH_TIMEOUT_MIN:-60}" # expected max runtime of watched workflow

GH_API="https://api.github.com"
SUMMARY_FILE="${GITHUB_STEP_SUMMARY:-}"

_TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/includes" 2>/dev/null && pwd || echo "")"

ts()    { date -u '+%H:%M:%S UTC'; }
info()  { echo "[quota-monitor] $(ts)  $*" >&2; }
warn()  { echo "[quota-monitor] $(ts) ⚠️  $*" >&2; }

summary_append() {
  [[ -n "$SUMMARY_FILE" ]] && echo "$1" >> "$SUMMARY_FILE"
}

# ── Shared helpers ────────────────────────────────────────────────────────────

format_epoch() {
  # Returns "HH:MM:SS UTC / H:MM:SS AM/PM UTC" dual-format string
  local epoch="$1"
  python3 -c "
import sys
sys.path.insert(0, '${_TF_DIR}')
try:
    from time_format import fmt_unix
    i = fmt_unix(${epoch})
    # Include seconds for log precision
    from datetime import datetime, timezone
    dt = datetime.fromtimestamp(${epoch}, tz=timezone.utc)
    s24 = dt.strftime('%H:%M:%S UTC')
    s12 = dt.strftime('%I:%M:%S %p UTC').lstrip('0') or '12:00:00 AM UTC'
    print(f'{s24} / {s12}')
except Exception:
    from datetime import datetime, timezone
    print(datetime.fromtimestamp(${epoch}, tz=timezone.utc).strftime('%H:%M:%S UTC'))
" 2>/dev/null || echo "${epoch}"
}

format_epoch_display() {
  # Returns full world-timezone display string for a given epoch
  local epoch="$1"
  python3 -c "
import sys
sys.path.insert(0, '${_TF_DIR}')
try:
    from time_format import fmt_unix
    print(fmt_unix(${epoch})['display'])
except Exception:
    from datetime import datetime, timezone
    print(datetime.fromtimestamp(${epoch}, tz=timezone.utc).strftime('%H:%M UTC'))
" 2>/dev/null || echo ""
}

format_duration() {
  local secs="$1"
  if   [[ "$secs" -le 0 ]];  then echo "now"
  elif [[ "$secs" -lt 60 ]]; then echo "${secs}s"
  else echo "$(( secs / 60 ))m$(( secs % 60 ))s"
  fi
}

# ── Rate limit helpers ────────────────────────────────────────────────────────
# fetch_all_quotas: outputs one line per bucket: "<name> <remaining> <limit> <reset_epoch>"

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

# get_bucket <lines> <name> → "<remaining> <limit> <reset_epoch>"
get_bucket() {
  echo "$1" | awk -v name="$2" '$1 == name { print $2, $3, $4 }'
}

# ── Dispatch helper ───────────────────────────────────────────────────────────

dispatch_workflow() {
  local wf="$1" ref="$2" inputs="$3"
  local payload
  payload=$(python3 -c "
import sys, json
print(json.dumps({'ref': sys.argv[1], 'inputs': json.loads(sys.argv[2])}))
" "$ref" "$inputs")

  curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "${GH_API}/repos/${OWNER}/${REPO}/actions/workflows/${wf}/dispatches"
}

# ── Watch mode helpers ────────────────────────────────────────────────────────
# fetch_latest_run <workflow_file> → "<run_id> <status> <conclusion> <created_epoch> <updated_epoch>"
# Returns exit code 2 specifically when the failure looks like quota exhaustion
# (empty body or rate-limit message) so the caller can back off appropriately.

fetch_latest_run() {
  local wf="$1"
  local raw http
  raw=$(curl -sf -w "\n%{http_code}" \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${GH_API}/repos/${OWNER}/${REPO}/actions/workflows/${wf}/runs?per_page=1" \
    2>/dev/null) || { warn "runs fetch failed for ${wf} (curl error)"; return 1; }

  http=$(echo "$raw" | tail -1)
  raw=$(echo "$raw" | sed '$d')

  if [[ "$http" == "403" || "$http" == "429" ]]; then
    return 2   # quota/rate-limit — caller should back off
  fi
  if [[ -z "$raw" ]]; then
    warn "runs fetch returned empty body (HTTP ${http}) for ${wf}"; return 1
  fi

  python3 -c "
import sys, json
from datetime import datetime, timezone

d = json.loads(sys.argv[1])
runs = d.get('workflow_runs', [])
if not runs:
    print('none none none 0 0')
    sys.exit(0)
r = runs[0]

def to_epoch(s):
    try:
        return int(datetime.strptime(s, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=timezone.utc).timestamp())
    except Exception:
        return 0

print(r['id'], r['status'], r.get('conclusion') or 'none',
      to_epoch(r['created_at']), to_epoch(r['updated_at']))
" "$raw"
}

# ── Quota mode ────────────────────────────────────────────────────────────────

run_quota_mode() {
  info "Mode: quota"
  info "  min_quota=${MIN_QUOTA}  buffer=${BUFFER_SEC}s  poll=${MIN_POLL_SEC}–${MAX_POLL_SEC}s  timeout=${TIMEOUT_MIN}m"
  [[ -n "$TARGET_WORKFLOW" ]] && info "  target=${OWNER}/${REPO} → ${TARGET_WORKFLOW}  ref=${TARGET_REF}"
  [[ -n "$TARGET_WORKFLOW" ]] && info "  inputs=${TARGET_INPUTS}"
  info ""

  summary_append "## Quota Monitor"
  summary_append ""
  if [[ -n "$TARGET_WORKFLOW" ]]; then
    summary_append "> **wait-trigger** — dispatches \`${TARGET_WORKFLOW}\` on \`${TARGET_REF}\` when core quota ≥ **${MIN_QUOTA}**"
  else
    summary_append "> **monitor-only** — exits when core quota ≥ **${MIN_QUOTA}**"
  fi
  summary_append ""
  summary_append "| Poll | Time (UTC 24h / 12h) | Core | GraphQL | Reset ETA | Next Poll |"
  summary_append "|---|---|---|---|---|---|"

  local attempt=0
  while true; do
    (( attempt++ )) || true
    local NOW; NOW=$(date +%s)

    [[ "$NOW" -ge "$DEADLINE" ]] && {
      warn "Timed out after ${TIMEOUT_MIN}m."
      summary_append ""
      summary_append "> ❌ Timed out after ${TIMEOUT_MIN}m without reaching quota threshold."
      return 1
    }

    local all_quotas
    all_quotas=$(fetch_all_quotas) || { sleep 30; continue; }

    local core_rem core_lim core_reset gql_rem gql_lim
    read -r core_rem core_lim core_reset < <(get_bucket "$all_quotas" "core")
    read -r gql_rem  gql_lim  _          < <(get_bucket "$all_quotas" "graphql")
    core_rem="${core_rem:-0}"; core_lim="${core_lim:-5000}"; core_reset="${core_reset:-0}"
    gql_rem="${gql_rem:-0}";   gql_lim="${gql_lim:-5000}"

    local reset_in=$(( core_reset - NOW ))
    local reset_str; reset_str=$(format_epoch "$core_reset")
    local eta_str;   eta_str=$(format_duration "$reset_in")
    local core_pct=$(( core_lim > 0 ? core_rem * 100 / core_lim : 0 ))
    local gql_pct=$(( gql_lim  > 0 ? gql_rem  * 100 / gql_lim  : 0 ))

    # Adaptive sleep: wake just after reset, clamped to [MIN, MAX]
    local raw_sleep sleep_sec
    raw_sleep=$(( reset_in > 0 ? reset_in + BUFFER_SEC : MIN_POLL_SEC ))
    sleep_sec=$(( raw_sleep < MIN_POLL_SEC ? MIN_POLL_SEC : raw_sleep ))
    sleep_sec=$(( sleep_sec > MAX_POLL_SEC ? MAX_POLL_SEC : sleep_sec ))

    info "#${attempt}  core=${core_rem}/${core_lim} (${core_pct}%)  graphql=${gql_rem}/${gql_lim} (${gql_pct}%)  reset_eta=${eta_str}  next_poll=${sleep_sec}s"
    summary_append "| #${attempt} | $(ts) | ${core_rem}/${core_lim} (${core_pct}%) | ${gql_rem}/${gql_lim} (${gql_pct}%) | ${eta_str} (${reset_str}) | ${sleep_sec}s |"

    if [[ "$core_rem" -ge "$MIN_QUOTA" ]]; then
      if [[ -z "$TARGET_WORKFLOW" ]]; then
        info "Quota sufficient (${core_rem} >= ${MIN_QUOTA}) — monitor-only, exiting."
        summary_append ""
        summary_append "> ✅ Core quota recovered to **${core_rem}** after ${attempt} poll(s). No target workflow configured."
        return 0
      fi

      info "Quota sufficient — dispatching ${TARGET_WORKFLOW}..."

      if [[ "$DRY_RUN" == "true" ]]; then
        info "DRY RUN — would dispatch ${TARGET_WORKFLOW} with inputs: ${TARGET_INPUTS}"
        summary_append ""
        summary_append "> 🔍 Dry run — would dispatch \`${TARGET_WORKFLOW}\` with quota at **${core_rem}**."
        return 0
      fi

      local http_status
      http_status=$(dispatch_workflow "$TARGET_WORKFLOW" "$TARGET_REF" "$TARGET_INPUTS")
      if [[ "$http_status" == "204" ]]; then
        info "✅ Dispatched ${TARGET_WORKFLOW} (HTTP 204) — quota at dispatch: ${core_rem}"
        summary_append ""
        summary_append "> ✅ Dispatched \`${TARGET_WORKFLOW}\` after ${attempt} poll(s). Core quota at dispatch: **${core_rem}**."
        return 0
      else
        warn "Dispatch returned HTTP ${http_status} — retrying next poll"
        summary_append ""
        summary_append "> ⚠️  Dispatch attempt #${attempt} returned HTTP ${http_status} — retrying in ${sleep_sec}s."
      fi
    fi

    info "  -> sleeping ${sleep_sec}s (reset in ${eta_str})"
    sleep "$sleep_sec"
  done
}

# ── Watch mode ────────────────────────────────────────────────────────────────

run_watch_mode() {
  : "${WATCH_WORKFLOW:?WATCH_WORKFLOW is required for watch mode}"

  local watch_timeout_sec=$(( WATCH_TIMEOUT_MIN * 60 ))

  info "Mode: watch"
  info "  watching=${OWNER}/${REPO} → ${WATCH_WORKFLOW}"
  info "  until=${WATCH_UNTIL}  expected_runtime=${WATCH_TIMEOUT_MIN}m  timeout=${TIMEOUT_MIN}m"
  info "  poll interval: adaptive — tight at start, widens as run ages toward ${WATCH_TIMEOUT_MIN}m"
  info ""

  summary_append "## Quota Monitor — Watch Mode"
  summary_append ""
  summary_append "> Watching \`${WATCH_WORKFLOW}\` until status = **${WATCH_UNTIL}** (expected runtime: ${WATCH_TIMEOUT_MIN}m)"
  summary_append ""
  summary_append "| Poll | Time (UTC 24h / 12h) | Run ID | Status | Conclusion | Run Age | Next Poll |"
  summary_append "|---|---|---|---|---|---|---|"

  local attempt=0
  while true; do
    (( attempt++ )) || true
    local NOW; NOW=$(date +%s)

    [[ "$NOW" -ge "$DEADLINE" ]] && {
      warn "Timed out after ${TIMEOUT_MIN}m waiting for ${WATCH_WORKFLOW} to reach '${WATCH_UNTIL}'."
      summary_append ""
      summary_append "> ❌ Timed out after ${TIMEOUT_MIN}m."
      return 1
    }

    local run_id status conclusion created_epoch updated_epoch fetch_rc
    fetch_latest_run "$WATCH_WORKFLOW" > /tmp/_qm_run_line 2>/dev/null
    fetch_rc=$?
    if [[ "$fetch_rc" -eq 2 ]]; then
      # Quota exhausted — fetch quota to get reset epoch and back off adaptively
      local all_quotas core_rem core_lim core_reset reset_in backoff_sleep
      all_quotas=$(curl -sf \
        -H "Authorization: token ${GH_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        "${GH_API}/rate_limit" 2>/dev/null) || all_quotas=""
      core_reset=$(python3 -c "
import sys,json
try:
    d=json.loads(sys.argv[1])
    print(d.get('resources',{}).get('core',{}).get('reset',0))
except Exception:
    print(0)
" "${all_quotas:-{}}" 2>/dev/null || echo 0)
      NOW=$(date +%s)
      reset_in=$(( core_reset - NOW ))
      local quota_buffer=45
      backoff_sleep=$(( reset_in > 0 ? reset_in + quota_buffer : MAX_POLL_SEC ))
      backoff_sleep=$(( backoff_sleep > MAX_POLL_SEC ? MAX_POLL_SEC : backoff_sleep ))
      warn "Quota exhausted during watch — backing off ${backoff_sleep}s (reset in $(format_duration $reset_in))"
      summary_append "| #${attempt} | $(ts) | quota exhausted | — | — | — | ${backoff_sleep}s |"
      sleep "$backoff_sleep"
      continue
    elif [[ "$fetch_rc" -ne 0 ]]; then
      sleep "$MIN_POLL_SEC"; continue
    fi
    read -r run_id status conclusion created_epoch updated_epoch < /tmp/_qm_run_line

    local run_age=0
    [[ "$created_epoch" -gt 0 ]] && run_age=$(( NOW - created_epoch ))
    local age_str; age_str=$(format_duration "$run_age")

    # Adaptive poll interval derived from run age relative to expected runtime:
    #   poll = lerp(MIN_POLL_SEC, MAX_POLL_SEC, run_age / watch_timeout_sec)
    # This means:
    #   - At age 0 (just queued)          → MIN_POLL_SEC  (tight)
    #   - At age = expected runtime        → MAX_POLL_SEC  (wide)
    #   - Clamped to [MIN_POLL_SEC, MAX_POLL_SEC] throughout
    # When waiting for in_progress specifically, also tighten near the
    # transition from queued → in_progress (typically first 60s).
    local poll_sec
    if [[ "$watch_timeout_sec" -gt 0 && "$run_age" -gt 0 ]]; then
      local range=$(( MAX_POLL_SEC - MIN_POLL_SEC ))
      poll_sec=$(( MIN_POLL_SEC + range * run_age / watch_timeout_sec ))
    else
      poll_sec="$MIN_POLL_SEC"
    fi
    # Clamp
    poll_sec=$(( poll_sec < MIN_POLL_SEC ? MIN_POLL_SEC : poll_sec ))
    poll_sec=$(( poll_sec > MAX_POLL_SEC ? MAX_POLL_SEC : poll_sec ))
    # Extra tightening: if watching for in_progress and run is queued/pending
    # and young (< 90s), poll at MIN_POLL_SEC to catch the transition quickly
    if [[ "$WATCH_UNTIL" == "in_progress" && \
          ( "$status" == "queued" || "$status" == "pending" ) && \
          "$run_age" -lt 90 ]]; then
      poll_sec="$MIN_POLL_SEC"
    fi

    info "#${attempt}  run=${run_id}  status=${status}  conclusion=${conclusion}  age=${age_str}  next_poll=${poll_sec}s"
    summary_append "| #${attempt} | $(ts) | [#${run_id}](https://github.com/${OWNER}/${REPO}/actions/runs/${run_id}) | \`${status}\` | \`${conclusion}\` | ${age_str} | ${poll_sec}s |"

    # Check exit condition
    if [[ "$WATCH_UNTIL" == "in_progress" && "$status" == "in_progress" ]] || \
       [[ "$WATCH_UNTIL" == "completed"   && "$status" == "completed"   ]]; then
      info "✅ ${WATCH_WORKFLOW} reached '${WATCH_UNTIL}' (conclusion: ${conclusion})"
      summary_append ""
      summary_append "> ✅ \`${WATCH_WORKFLOW}\` reached **${WATCH_UNTIL}** after ${attempt} poll(s). Conclusion: \`${conclusion}\`."
      # Propagate failure/cancellation to caller
      [[ "$conclusion" == "failure" || "$conclusion" == "cancelled" ]] && return 1
      return 0
    fi

    [[ "$run_id" == "none" ]] && info "  No runs found yet — waiting..."

    info "  -> sleeping ${poll_sec}s"
    sleep "$poll_sec"
  done
}

# ── Entry point ───────────────────────────────────────────────────────────────

START_EPOCH=$(date +%s)
TIMEOUT_SEC=$(( TIMEOUT_MIN * 60 ))
DEADLINE=$(( START_EPOCH + TIMEOUT_SEC ))

case "$MODE" in
  watch) run_watch_mode ;;
  quota) run_quota_mode ;;
  *)     warn "Unknown MODE '${MODE}' — expected quota or watch"; exit 1 ;;
esac
