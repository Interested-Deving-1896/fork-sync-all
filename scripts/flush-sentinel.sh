#!/usr/bin/env bash
#
# flush-sentinel.sh — runner slot reservation + queue clearing for flush pipeline
#
# Two responsibilities:
#
#   1. QUEUE CLEAR (run before flush starts)
#      Cancels all non-CRITICAL queued runs so the flush pipeline has maximum
#      runner availability. Tier 1 (CRITICAL) runs are never touched.
#      Tier 2 (HIGH) runs are cancelled only if AGGRESSIVE_CLEAR=true.
#
#   2. KEEPALIVE (run as a background job during flush)
#      Holds a runner slot open by sleeping in a loop, preventing GitHub from
#      reclaiming the slot between flush stages. The sentinel exits when
#      FLUSH_RUN_ID completes or SENTINEL_MAX_MINUTES is reached.
#
# Usage:
#   # Queue clear (call once before dispatching flush):
#   bash scripts/flush-sentinel.sh clear
#
#   # Keepalive (call in a parallel job, exits when flush run completes):
#   FLUSH_RUN_ID=12345 bash scripts/flush-sentinel.sh keepalive
#
# Required env vars:
#   GH_TOKEN          — PAT with actions:write scope
#   GITHUB_REPOSITORY — owner/repo (set automatically in Actions)
#
# Optional env vars:
#   AGGRESSIVE_CLEAR      — if "true", also cancel tier 2 (HIGH) queued runs
#                           (default: false — only tier 3/4 are cleared)
#   SENTINEL_MAX_MINUTES  — max minutes the keepalive will hold the slot
#                           (default: 360 — 6 hours, covers longest flush)
#   FLUSH_RUN_ID          — run ID to watch; keepalive exits when it completes
#   SENTINEL_POLL_SECONDS — how often to poll run status (default: 60)
#   DRY_RUN               — if "true", print actions without executing

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/includes/gh-api.sh"

GH_TOKEN="${GH_TOKEN:-}"
REPO="${GITHUB_REPOSITORY:-Interested-Deving-1896/fork-sync-all}"
AGGRESSIVE_CLEAR="${AGGRESSIVE_CLEAR:-false}"
SENTINEL_MAX_MINUTES="${SENTINEL_MAX_MINUTES:-360}"
# WATCH_JOB_NAME — if set, poll a specific job name within FLUSH_RUN_ID
# (or GITHUB_RUN_ID if FLUSH_RUN_ID is unset) instead of the whole run.
# Use this when the sentinel is part of the same run as the job it watches
# (watching the run itself would deadlock since the run stays in_progress
# while the sentinel is running).
WATCH_JOB_NAME="${WATCH_JOB_NAME:-}"
# WATCH_JOB_PREFIX — if set, exit when ALL jobs whose name starts with this
# prefix are completed. Takes precedence over WATCH_JOB_NAME.
WATCH_JOB_PREFIX="${WATCH_JOB_PREFIX:-}"
FLUSH_RUN_ID="${FLUSH_RUN_ID:-}"
SENTINEL_POLL_SECONDS="${SENTINEL_POLL_SECONDS:-60}"
DRY_RUN="${DRY_RUN:-false}"

GH_API="https://api.github.com"
MODE="${1:-clear}"

info()  { echo "[flush-sentinel] $*" >&2; }
warn()  { echo "[flush-sentinel:warn] $*" >&2; }
dry()   { echo "[flush-sentinel:dry-run] $*" >&2; }

# ── Load priority tiers ───────────────────────────────────────────────────────
# Returns the tier number (1-4) for a workflow name. Defaults to 3 (MEDIUM).
get_tier() {
  local workflow_name="$1"
  python3 - "${SCRIPT_DIR}/../config/workflow-priority-tiers.yml" "${workflow_name}" << 'PYEOF'
import yaml, sys
config_path, wf_name = sys.argv[1], sys.argv[2]
try:
    config = yaml.safe_load(open(config_path))
    tiers = config.get("tiers", {})
    for tier_num, tier_data in tiers.items():
        workflows = tier_data.get("workflows", [])
        if any(wf_name == w.get("name", w) if isinstance(w, dict) else wf_name == w for w in workflows):
            print(tier_num)
            sys.exit(0)
    print(3)  # default MEDIUM
except Exception:
    print(3)
PYEOF
}

# ── Queue clear ───────────────────────────────────────────────────────────────
do_queue_clear() {
  # Wait for quota to recover before attempting cancellations.
  # Each cancel call costs 1 REST call; with 100+ queued runs this adds up.
  local _quota _reset _wait
  _quota=$(curl -sf -H "Authorization: token ${GH_TOKEN}" \
    "https://api.github.com/rate_limit" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['resources']['core']['remaining'])" 2>/dev/null || echo "0")
  if [[ "${_quota}" -lt 200 ]]; then
    _reset=$(curl -sf -H "Authorization: token ${GH_TOKEN}" \
      "https://api.github.com/rate_limit" \
      | python3 -c "import json,sys,datetime; d=json.load(sys.stdin); r=d['resources']['core']['reset']; print(max(0,r-int(__import__('time').time())+5))" 2>/dev/null || echo "60")
    _wait=$(( _reset > 3700 ? 3700 : _reset ))
    info "Quota too low (${_quota}) for queue clear — waiting ${_wait}s for reset"
    sleep "${_wait}"
  fi
  info "Clearing queued runs to free runner slots for flush pipeline..."
  info "  Aggressive clear: ${AGGRESSIVE_CLEAR}"

  local queued_runs
  queued_runs=$(gh_get "${GH_API}/repos/${REPO}/actions/runs?status=queued&per_page=100" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); [print(r['id'], r['name']) for r in d.get('workflow_runs',[])]" 2>/dev/null || echo "")

  if [[ -z "${queued_runs}" ]]; then
    info "No queued runs found — queue is clear"
    return 0
  fi

  local cancelled=0 skipped=0
  while IFS=' ' read -r run_id run_name; do
    [[ -z "${run_id}" ]] && continue

    local tier
    tier=$(get_tier "${run_name}")

    # Never cancel tier 1 (CRITICAL)
    if [[ "${tier}" == "1" ]]; then
      info "  SKIP (tier 1 CRITICAL): ${run_name} [${run_id}]"
      ((skipped++)) || true
      continue
    fi

    # Skip tier 2 (HIGH) unless aggressive clear
    if [[ "${tier}" == "2" ]] && [[ "${AGGRESSIVE_CLEAR}" != "true" ]]; then
      info "  SKIP (tier 2 HIGH, not aggressive): ${run_name} [${run_id}]"
      ((skipped++)) || true
      continue
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
      dry "  Would cancel tier ${tier}: ${run_name} [${run_id}]"
      ((cancelled++)) || true
      continue
    fi

    if gh_api "POST" "${GH_API}/repos/${REPO}/actions/runs/${run_id}/cancel" > /dev/null 2>&1; then
      info "  Cancelled tier ${tier}: ${run_name} [${run_id}]"
      ((cancelled++)) || true
    else
      warn "  Failed to cancel: ${run_name} [${run_id}]"
    fi
  done <<< "${queued_runs}"

  info "Queue clear complete: ${cancelled} cancelled, ${skipped} skipped"
  echo "sentinel_cleared=${cancelled}" >> "${GITHUB_OUTPUT:-/dev/null}"
}

# ── Keepalive ─────────────────────────────────────────────────────────────────
do_keepalive() {
  local max_seconds=$(( SENTINEL_MAX_MINUTES * 60 ))
  local elapsed=0
  # When watching a job within the current run, use GITHUB_RUN_ID as the run.
  local watch_run="${FLUSH_RUN_ID:-${GITHUB_RUN_ID:-}}"

  info "Keepalive started — holding runner slot for up to ${SENTINEL_MAX_MINUTES} min"
  if [[ -n "${WATCH_JOB_PREFIX}" ]]; then
    info "  Watching all jobs prefixed '${WATCH_JOB_PREFIX}' in run ${watch_run}"
  elif [[ -n "${WATCH_JOB_NAME}" ]]; then
    info "  Watching job '${WATCH_JOB_NAME}' in run ${watch_run}"
  elif [[ -n "${watch_run}" ]]; then
    info "  Watching run: ${watch_run}"
  fi

  while [[ ${elapsed} -lt ${max_seconds} ]]; do
    sleep "${SENTINEL_POLL_SECONDS}"
    elapsed=$(( elapsed + SENTINEL_POLL_SECONDS ))

    if [[ -n "${WATCH_JOB_PREFIX}" && -n "${watch_run}" ]]; then
      # Poll all jobs whose name starts with the prefix — exits when all done.
      local prefix_status
      prefix_status=$(gh_get "${GH_API}/repos/${REPO}/actions/runs/${watch_run}/jobs" \
        | python3 -c "
import json,sys
prefix = '${WATCH_JOB_PREFIX}'
jobs = json.load(sys.stdin).get('jobs', [])
matched = [j for j in jobs if j.get('name','').startswith(prefix)]
if not matched:
    print('not_found')
elif all(j.get('status') == 'completed' for j in matched):
    print('all_completed')
else:
    statuses = ','.join(f\"{j['name']}={j.get('status','?')}\" for j in matched)
    print(statuses)
" 2>/dev/null || echo "unknown")

      if [[ "${prefix_status}" == "all_completed" ]]; then
        info "All '${WATCH_JOB_PREFIX}' jobs completed — releasing runner slot"
        echo "sentinel_exit=jobs_completed" >> "${GITHUB_OUTPUT:-/dev/null}"
        return 0
      fi
      info "  [${elapsed}s/${max_seconds}s] ${prefix_status} — holding slot"

    elif [[ -n "${WATCH_JOB_NAME}" && -n "${watch_run}" ]]; then
      # Poll a specific job by name within the run — avoids deadlock when
      # sentinel and watched job are in the same workflow run.
      local job_status
      job_status=$(gh_get "${GH_API}/repos/${REPO}/actions/runs/${watch_run}/jobs" \
        | python3 -c "
import json,sys
jobs = json.load(sys.stdin).get('jobs', [])
match = [j for j in jobs if j.get('name') == '${WATCH_JOB_NAME}']
print(match[0].get('status', 'unknown') if match else 'not_found')
" 2>/dev/null || echo "unknown")

      if [[ "${job_status}" == "completed" ]]; then
        info "Job '${WATCH_JOB_NAME}' completed — releasing runner slot"
        echo "sentinel_exit=job_completed" >> "${GITHUB_OUTPUT:-/dev/null}"
        return 0
      fi
      info "  [${elapsed}s/${max_seconds}s] Job '${WATCH_JOB_NAME}' status: ${job_status} — holding slot"

    elif [[ -n "${watch_run}" ]]; then
      # Poll the whole run status (used when sentinel is in a different run).
      local run_status
      run_status=$(gh_get "${GH_API}/repos/${REPO}/actions/runs/${watch_run}" \
        | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('status','unknown'))" 2>/dev/null || echo "unknown")

      if [[ "${run_status}" == "completed" ]]; then
        info "Run ${watch_run} completed — releasing runner slot"
        echo "sentinel_exit=flush_completed" >> "${GITHUB_OUTPUT:-/dev/null}"
        return 0
      fi
      info "  [${elapsed}s/${max_seconds}s] Run status: ${run_status} — holding slot"

    else
      info "  [${elapsed}s/${max_seconds}s] Holding runner slot (no run/job to watch)"
    fi
  done

  warn "Sentinel max time (${SENTINEL_MAX_MINUTES} min) reached — releasing slot"
  echo "sentinel_exit=timeout" >> "${GITHUB_OUTPUT:-/dev/null}"
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
case "${MODE}" in
  clear)     do_queue_clear ;;
  keepalive) do_keepalive ;;
  *)
    echo "Usage: $0 {clear|keepalive}" >&2
    exit 1
    ;;
esac
