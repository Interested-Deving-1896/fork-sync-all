#!/usr/bin/env bash
#
# Local quota watcher — runs in this Gitpod environment (not on a GitHub runner).
#
# Combines three operations that previously required inline Python each time:
#
#   1. Sleep efficiently until the rate limit reset epoch (one long sleep to
#      just before the reset, then tight 5s polls until remaining > 0).
#   2. Cancel a list of stale/redundant queued runs.
#   3. Optionally dispatch a target workflow once quota is confirmed available.
#
# Adaptive sleep strategy:
#   - Fetch the live reset_epoch from /rate_limit.
#   - Sleep until (reset_epoch - WAKE_BEFORE_SEC), so we arrive just before
#     the reset rather than polling every N seconds for an hour.
#   - Switch to tight TIGHT_POLL_SEC polls until remaining > 0.
#   - This uses ~3 API calls total for the wait phase regardless of how far
#     away the reset is, vs. O(reset_minutes / poll_interval) for fixed polling.
#
# Usage:
#   GH_TOKEN=... bash scripts/local-quota-watch.sh [options]
#
# Options (all optional — defaults shown):
#   --cancel  <run_id> [run_id ...]   Run IDs to cancel after quota recovers
#   --dispatch <workflow.yml>         Workflow to dispatch after cancellations
#   --inputs  '<json>'                Inputs JSON for the dispatched workflow
#   --ref     <ref>                   Git ref for dispatch (default: main)
#   --min-quota <n>                   Minimum remaining before dispatching (default: 2000)
#   --wake-before <sec>               Seconds before reset to wake up (default: 15)
#   --tight-poll <sec>                Poll interval during tight phase (default: 5)
#   --dry-run                         Print what would happen without doing it
#
# Required env vars:
#   GH_TOKEN   — token with repo + workflow + actions:write scopes
#
# Optional env vars (override defaults):
#   GITHUB_OWNER   — default: Interested-Deving-1896
#   GITHUB_REPO    — default: fork-sync-all

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"

OWNER="${GITHUB_OWNER:-Interested-Deving-1896}"
REPO="${GITHUB_REPO:-fork-sync-all}"
GH_API="https://api.github.com"

# Defaults
CANCEL_IDS=()
DISPATCH_WF=""
DISPATCH_INPUTS="{}"
DISPATCH_REF="main"
MIN_QUOTA=2000
WAKE_BEFORE_SEC=15
TIGHT_POLL_SEC=5
DRY_RUN=false

ts()   { date -u '+%H:%M:%S UTC'; }
info() { echo "[local-watch] $(ts)  $*"; }
warn() { echo "[local-watch] $(ts) ⚠️  $*" >&2; }

# ── Argument parsing ──────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cancel)
      shift
      while [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]]; do
        CANCEL_IDS+=("$1"); shift
      done ;;
    --dispatch)    DISPATCH_WF="$2";      shift 2 ;;
    --inputs)      DISPATCH_INPUTS="$2";  shift 2 ;;
    --ref)         DISPATCH_REF="$2";     shift 2 ;;
    --min-quota)   MIN_QUOTA="$2";        shift 2 ;;
    --wake-before) WAKE_BEFORE_SEC="$2";  shift 2 ;;
    --tight-poll)  TIGHT_POLL_SEC="$2";   shift 2 ;;
    --dry-run)     DRY_RUN=true;          shift   ;;
    *) warn "Unknown option: $1"; exit 1 ;;
  esac
done

# ── API helpers ───────────────────────────────────────────────────────────────

fetch_core_quota() {
  # Returns "<remaining> <reset_epoch>" — uses unauthenticated-friendly endpoint
  # so this call itself doesn't consume core quota.
  local raw
  raw=$(curl -sf \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${GH_API}/rate_limit" 2>/dev/null) || { warn "rate_limit fetch failed"; echo "0 0"; return; }
  python3 -c "
import sys, json
d = json.loads(sys.argv[1])
core = d['resources']['core']
print(core['remaining'], core['reset'])
" "$raw"
}

cancel_run() {
  local run_id="$1"
  local http
  http=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${GH_API}/repos/${OWNER}/${REPO}/actions/runs/${run_id}/cancel")
  echo "$http"
}

dispatch_workflow() {
  local payload
  payload=$(python3 -c "
import sys, json
print(json.dumps({'ref': sys.argv[1], 'inputs': json.loads(sys.argv[2])}))
" "$DISPATCH_REF" "$DISPATCH_INPUTS")
  local http
  http=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "${GH_API}/repos/${OWNER}/${REPO}/actions/workflows/${DISPATCH_WF}/dispatches")
  echo "$http"
}

format_duration() {
  local secs="$1"
  if   [[ "$secs" -le 0 ]];  then echo "now"
  elif [[ "$secs" -lt 60 ]]; then echo "${secs}s"
  else echo "$(( secs / 60 ))m$(( secs % 60 ))s"
  fi
}

# ── Summary ───────────────────────────────────────────────────────────────────

info "local-quota-watch starting"
info "  min_quota=${MIN_QUOTA}  wake_before=${WAKE_BEFORE_SEC}s  tight_poll=${TIGHT_POLL_SEC}s"
[[ "${#CANCEL_IDS[@]}" -gt 0 ]] && info "  cancel: ${CANCEL_IDS[*]}"
[[ -n "$DISPATCH_WF" ]]         && info "  dispatch: ${DISPATCH_WF}  ref=${DISPATCH_REF}  inputs=${DISPATCH_INPUTS}"
[[ "$DRY_RUN" == "true" ]]      && info "  DRY RUN — no writes will be made"
info ""

# ── Phase 1: fetch reset epoch and sleep until just before it ─────────────────

read -r remaining reset_epoch < <(fetch_core_quota)
remaining="${remaining:-0}"
reset_epoch="${reset_epoch:-0}"
NOW=$(date +%s)

reset_str=$(python3 -c "
from datetime import datetime, timezone
print(datetime.fromtimestamp(${reset_epoch}, tz=timezone.utc).strftime('%H:%M:%S UTC'))
" 2>/dev/null || echo "${reset_epoch}")

info "Current core quota: ${remaining}/5000"
info "Reset at: ${reset_str}"

if [[ "$remaining" -ge "$MIN_QUOTA" ]]; then
  info "Quota already sufficient — skipping wait phase."
else
  wake_at=$(( reset_epoch - WAKE_BEFORE_SEC ))
  sleep_sec=$(( wake_at - NOW ))

  if [[ "$sleep_sec" -gt 0 ]]; then
    eta=$(format_duration "$sleep_sec")
    info "Sleeping ${eta} (until ${WAKE_BEFORE_SEC}s before reset)..."
    [[ "$DRY_RUN" == "true" ]] && info "DRY RUN — would sleep ${sleep_sec}s" || sleep "$sleep_sec"
  fi

  # ── Phase 2: tight poll until remaining > 0 ──────────────────────────────

  info "Entering tight poll (every ${TIGHT_POLL_SEC}s)..."
  for attempt in $(seq 1 60); do
    read -r remaining reset_epoch < <(fetch_core_quota)
    remaining="${remaining:-0}"
    reset_epoch="${reset_epoch:-0}"
    NOW=$(date +%s)

    # Recalculate reset ETA in case it slid
    reset_str=$(python3 -c "
from datetime import datetime, timezone
print(datetime.fromtimestamp(${reset_epoch}, tz=timezone.utc).strftime('%H:%M:%S UTC'))
" 2>/dev/null || echo "${reset_epoch}")
    reset_in=$(( reset_epoch - NOW ))
    eta=$(format_duration "$reset_in")

    info "  #${attempt}  remaining=${remaining}  reset_eta=${eta} (${reset_str})"

    if [[ "$remaining" -ge "$MIN_QUOTA" ]]; then
      info "Quota recovered: ${remaining} >= ${MIN_QUOTA}"
      break
    fi

    # If reset slid forward significantly (> 30s), break out of tight poll
    # and go back to a long sleep to avoid hammering the API
    if [[ "$reset_in" -gt 30 ]]; then
      info "Reset slid to ${reset_str} (${eta} away) — switching back to long sleep..."
      wake_at=$(( reset_epoch - WAKE_BEFORE_SEC ))
      sleep_sec=$(( wake_at - NOW ))
      if [[ "$sleep_sec" -gt 0 ]]; then
        info "Sleeping ${sleep_sec}s..."
        [[ "$DRY_RUN" == "true" ]] || sleep "$sleep_sec"
      fi
      info "Re-entering tight poll..."
    else
      [[ "$DRY_RUN" == "true" ]] || sleep "$TIGHT_POLL_SEC"
    fi
  done

  if [[ "$remaining" -lt "$MIN_QUOTA" ]]; then
    warn "Quota never recovered above ${MIN_QUOTA} — giving up."
    exit 1
  fi
fi

# ── Phase 3: cancel stale runs ────────────────────────────────────────────────

if [[ "${#CANCEL_IDS[@]}" -gt 0 ]]; then
  info ""
  info "Cancelling ${#CANCEL_IDS[@]} stale run(s)..."
  for run_id in "${CANCEL_IDS[@]}"; do
    if [[ "$DRY_RUN" == "true" ]]; then
      info "  DRY RUN — would cancel #${run_id}"
    else
      http=$(cancel_run "$run_id")
      info "  #${run_id}  HTTP ${http}"
      sleep 0.5
    fi
  done
  # Brief pause to let cancellations register before dispatching
  [[ "$DRY_RUN" == "true" ]] || sleep 3
fi

# ── Phase 4: dispatch target workflow ─────────────────────────────────────────

if [[ -n "$DISPATCH_WF" ]]; then
  info ""
  info "Dispatching ${DISPATCH_WF}..."
  if [[ "$DRY_RUN" == "true" ]]; then
    info "DRY RUN — would dispatch ${DISPATCH_WF} with ref=${DISPATCH_REF} inputs=${DISPATCH_INPUTS}"
  else
    http=$(dispatch_workflow)
    if [[ "$http" == "204" ]]; then
      info "✅ Dispatched ${DISPATCH_WF} (HTTP 204)"
    else
      warn "Dispatch returned HTTP ${http}"
      exit 1
    fi
  fi
fi

info ""
info "Done."
