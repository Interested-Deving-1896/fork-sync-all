#!/usr/bin/env bash
#
# Dispatches a workflow and polls until it completes.
#
# Usage: dispatch-and-wait.sh <workflow_file> [timeout_minutes] [inputs_json]
#
# Required env vars:
#   GH_TOKEN  — PAT with actions:write
#   REPO      — owner/repo (e.g. Interested-Deving-1896/fork-sync-all)
# Optional env vars:
#   DISPATCH_CANCEL_EXIT_CODE — 2 (default) or 0 when cancellation is an
#                               explicitly accepted skip
#   DISPATCH_CANCEL_RETRIES   — number of times to re-dispatch a cancelled run
#                               before returning DISPATCH_CANCEL_EXIT_CODE
#   DISPATCH_PRIORITY         — capacity priority 1 (critical) through 4 (low)
#                               (default 2)
#   DISPATCH_CAPACITY_WAIT    — seconds to wait for admission (default 900)
#   DISPATCH_CAPACITY_POLL    — seconds between live rechecks (default 120)
#   DISPATCH_COMPLETION_POLL  — seconds between child completion checks
#                               (default 120; set explicitly for a faster wait)
#   DISPATCH_MIN_QUOTA        — explicit REST quota floor override; otherwise
#                               resolved from the child workflow's registry entry
#   DISPATCH_CAPACITY_SLOTS   — peak hosted-runner slots needed by the child
#                               workflow (default 1)
#   DISPATCH_CANCEL_ON_TIMEOUT — cancel the exact child run when polling times
#                                out (default true)
#   DISPATCH_CANCEL_ADOPTED_ON_TIMEOUT — also cancel a pre-existing adopted run
#                                        on timeout (default false)
#   DISPATCH_ESTATE_DRAIN     — drain managed-consumer fallback runs before a
#                               new dispatch (default false)
#   DISPATCH_ESTATE_DRAIN_INTERVAL — minimum seconds between estate scans for
#                                    one parent run (default 900)
#   FORGE_CAPACITY_ENABLED    — false disables capacity admission (default true)
#   FORGE_CAPACITY_REQUIRED   — true fails closed if observation is unavailable
#   DISPATCH_NO_WAIT          — true returns after the exact run is identified
#
# Exit codes:
#   0 — workflow completed with success or skipped
#   1 — dispatch failed, timed out, or workflow concluded with failure
#   2 — workflow was cancelled (retriable, not a real failure)

set -uo pipefail

WORKFLOW="${1:?workflow file required}"
TIMEOUT_MIN="${2:-90}"
INPUTS="${3-}"
[[ -n "$INPUTS" ]] || INPUTS='{}'
API="https://api.github.com"
API_VERSION="${GITHUB_API_VERSION:-2026-03-10}"
DISPATCH_CANCEL_EXIT_CODE="${DISPATCH_CANCEL_EXIT_CODE:-2}"
DISPATCH_CANCEL_RETRIES="${DISPATCH_CANCEL_RETRIES:-0}"
DISPATCH_PRIORITY="${DISPATCH_PRIORITY:-2}"
DISPATCH_CAPACITY_WAIT="${DISPATCH_CAPACITY_WAIT:-900}"
DISPATCH_CAPACITY_POLL="${DISPATCH_CAPACITY_POLL:-120}"
DISPATCH_COMPLETION_POLL="${DISPATCH_COMPLETION_POLL:-120}"
DISPATCH_MIN_QUOTA="${DISPATCH_MIN_QUOTA:-}"
DISPATCH_CAPACITY_SLOTS="${DISPATCH_CAPACITY_SLOTS:-1}"
DISPATCH_CANCEL_ON_TIMEOUT="${DISPATCH_CANCEL_ON_TIMEOUT:-true}"
DISPATCH_CANCEL_ADOPTED_ON_TIMEOUT="${DISPATCH_CANCEL_ADOPTED_ON_TIMEOUT:-false}"
DISPATCH_ESTATE_DRAIN="${DISPATCH_ESTATE_DRAIN:-false}"
DISPATCH_ESTATE_DRAIN_INTERVAL="${DISPATCH_ESTATE_DRAIN_INTERVAL:-900}"
FORGE_CAPACITY_ENABLED="${FORGE_CAPACITY_ENABLED:-true}"
FORGE_CAPACITY_REQUIRED="${FORGE_CAPACITY_REQUIRED:-false}"
DISPATCH_NO_WAIT="${DISPATCH_NO_WAIT:-false}"
[[ "$DISPATCH_CANCEL_EXIT_CODE" == "0" || "$DISPATCH_CANCEL_EXIT_CODE" == "2" ]] \
  || { echo "DISPATCH_CANCEL_EXIT_CODE must be 0 or 2" >&2; exit 1; }
[[ "$DISPATCH_CANCEL_RETRIES" =~ ^[0-9]+$ ]] \
  || { echo "DISPATCH_CANCEL_RETRIES must be a non-negative integer" >&2; exit 1; }
[[ "$DISPATCH_PRIORITY" =~ ^[1-4]$ ]] \
  || { echo "DISPATCH_PRIORITY must be 1, 2, 3, or 4" >&2; exit 1; }
[[ "$DISPATCH_CAPACITY_WAIT" =~ ^[0-9]+$ ]] \
  || { echo "DISPATCH_CAPACITY_WAIT must be a non-negative integer" >&2; exit 1; }
[[ "$DISPATCH_CAPACITY_POLL" =~ ^[1-9][0-9]*$ ]] \
  || { echo "DISPATCH_CAPACITY_POLL must be a positive integer" >&2; exit 1; }
[[ "$DISPATCH_COMPLETION_POLL" =~ ^[1-9][0-9]*$ ]] \
  || { echo "DISPATCH_COMPLETION_POLL must be a positive integer" >&2; exit 1; }
[[ -z "$DISPATCH_MIN_QUOTA" || "$DISPATCH_MIN_QUOTA" =~ ^[1-9][0-9]*$ ]] \
  || { echo "DISPATCH_MIN_QUOTA must be a positive integer" >&2; exit 1; }
[[ "$DISPATCH_CAPACITY_SLOTS" =~ ^[1-9][0-9]*$ ]] \
  || { echo "DISPATCH_CAPACITY_SLOTS must be a positive integer" >&2; exit 1; }
[[ "$TIMEOUT_MIN" =~ ^[1-9][0-9]*$ ]] \
  || { echo "timeout_minutes must be a positive integer" >&2; exit 1; }
[[ "$DISPATCH_NO_WAIT" == "true" || "$DISPATCH_NO_WAIT" == "false" ]] \
  || { echo "DISPATCH_NO_WAIT must be true or false" >&2; exit 1; }
[[ "$DISPATCH_CANCEL_ON_TIMEOUT" == "true" || "$DISPATCH_CANCEL_ON_TIMEOUT" == "false" ]] \
  || { echo "DISPATCH_CANCEL_ON_TIMEOUT must be true or false" >&2; exit 1; }
[[ "$DISPATCH_CANCEL_ADOPTED_ON_TIMEOUT" == "true" || "$DISPATCH_CANCEL_ADOPTED_ON_TIMEOUT" == "false" ]] \
  || { echo "DISPATCH_CANCEL_ADOPTED_ON_TIMEOUT must be true or false" >&2; exit 1; }
[[ "$DISPATCH_ESTATE_DRAIN" == "true" || "$DISPATCH_ESTATE_DRAIN" == "false" ]] \
  || { echo "DISPATCH_ESTATE_DRAIN must be true or false" >&2; exit 1; }
[[ "$DISPATCH_ESTATE_DRAIN_INTERVAL" =~ ^[0-9]+$ ]] \
  || { echo "DISPATCH_ESTATE_DRAIN_INTERVAL must be a non-negative integer" >&2; exit 1; }

_TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/includes" 2>/dev/null && pwd || echo "")"
_SCRIPT_DIR="$(dirname "$_TF_DIR")"

_now_dual() {
  # Emit "HH:MM UTC / H:MM AM/PM UTC" for the current moment
  python3 -c "
import sys, os
sys.path.insert(0, '${_TF_DIR}')
from datetime import datetime, timezone
dt = datetime.now(timezone.utc)
s24 = dt.strftime('%H:%M:%S UTC')
s12 = dt.strftime('%I:%M:%S %p UTC').lstrip('0') or '12:00:00 AM UTC'
try:
    from time_format import fmt_dt
    disp = fmt_dt(dt)['display']
    print(f'{s24} / {s12}')
    print(f'  [{disp}]', file=sys.stderr)
except Exception:
    print(s24)
" 2>/dev/null || date -u '+%H:%M:%S UTC'
}

info() { echo "[dispatch-wait] $*" >&2; }
ok()   { echo "[dispatch-wait] ✓ $*" >&2; }
fail() { echo "[dispatch-wait] ✗ $1" >&2; exit "${2:-1}"; }

_resolve_dispatch_min_quota() {
  if [[ -n "$DISPATCH_MIN_QUOTA" ]]; then
    printf '%s\n' "$DISPATCH_MIN_QUOTA"
    return 0
  fi

  local workflow_path="${_SCRIPT_DIR}/../.github/workflows/${WORKFLOW}"
  local workflow_name=""
  if [[ -f "$workflow_path" ]]; then
    workflow_name=$(python3 - "$workflow_path" <<'PYEOF' 2>/dev/null || true
import sys, yaml
with open(sys.argv[1]) as handle:
    workflow = yaml.safe_load(handle) or {}
print(workflow.get("name", ""))
PYEOF
    )
  fi

  source "${_TF_DIR}/budget.sh"
  workflow_min_quota "${workflow_name:-$WORKFLOW}"
}

_build_dispatch_body() {
  python3 -c "
import json,sys
inputs=json.loads(sys.argv[1])
if not isinstance(inputs, dict):
    raise SystemExit('inputs_json must be a JSON object')
sys.stdout.write(json.dumps({'ref':'main','inputs':inputs},separators=(',',':')))
" "$INPUTS"
}

# Validate once before making any API calls. Invalid input must fail closed;
# silently replacing it with {} would run child workflows with live defaults.
if ! _build_dispatch_body >/dev/null; then
  fail "inputs_json must be a valid JSON object"
fi

# No-network diagnostic used by regression tests and local troubleshooting.
if [[ "${DISPATCH_VALIDATE_ONLY:-false}" == "true" ]]; then
  _build_dispatch_body
  exit 0
fi

_DISPATCH_QUOTA_FLOOR=$(_resolve_dispatch_min_quota)
[[ "$_DISPATCH_QUOTA_FLOOR" =~ ^[1-9][0-9]*$ ]] \
  || fail "Resolved dispatch quota floor must be a positive integer"
if [[ "${DISPATCH_QUOTA_ONLY:-false}" == "true" ]]; then
  printf '%s\n' "$_DISPATCH_QUOTA_FLOOR"
  exit 0
fi

# Record time before dispatch so we can find the new run (ISO — machine-facing)
BEFORE_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

info "Dispatching ${WORKFLOW}..."

# ── Adopt existing run (idempotency) ─────────────────────────────────────────
# If a run of this workflow is already queued or in_progress AND was created
# within the last ADOPT_WINDOW_SEC seconds, adopt the oldest one instead of
# dispatching a duplicate. This handles the case where the caller is
# re-triggered while a prior dispatch is still running (e.g. lifecycle
# manually re-fired mid-pre-flush-prep).
#
# The recency window is critical: workflows like reconcile-org-refs.yml and
# verify-mirror-integrity.yml are dispatched multiple times per pipeline with
# different inputs. Without a window, Stage 8 (orgs=osp-only) would adopt
# Stage 4's still-running (orgs=id-1896-only) run — wrong scope. The window
# ensures we only adopt a run that was dispatched by this same caller
# invocation, not one from a prior stage or an external trigger.
#
# When multiple runs fall within the window (racing duplicates), we pick the
# oldest by created_at — furthest along, most likely to complete.
ADOPT_WINDOW_SEC="${ADOPT_WINDOW_SEC:-300}"  # 5 min default; override via env

_find_active_run() {
  local status="$1"
  local before_ts="$2"
  local window_sec="$3"
  curl -sf \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: ${API_VERSION}" \
    "${API}/repos/${REPO}/actions/workflows/${WORKFLOW}/runs?event=workflow_dispatch&branch=main&status=${status}&per_page=10" \
    | python3 -c "
import json, sys
from datetime import datetime, timezone, timedelta
runs = json.load(sys.stdin).get('workflow_runs', [])
if not runs:
    sys.exit(0)
before = datetime.fromisoformat('${before_ts}'.replace('Z','+00:00'))
window = timedelta(seconds=int('${window_sec}'))
# Only consider runs created within [before - window, before]
candidates = [
    r for r in runs
    if r.get('event') == 'workflow_dispatch'
       and r.get('head_branch') == 'main'
       and (before - window)
       <= datetime.fromisoformat(r['created_at'].replace('Z','+00:00'))
       <= before
]
if not candidates:
    sys.exit(0)
# Pick oldest candidate — furthest along, most likely to complete
oldest = min(candidates, key=lambda r: r['created_at'])
print(oldest['id'])
" 2>/dev/null || echo ""
}

_wait_for_capacity() {
  [[ "$FORGE_CAPACITY_ENABLED" == "true" ]] || {
    info "Forge capacity admission disabled — proceeding"
    return 0
  }

  local script_dir scope observation decision rc elapsed=0 force_live=false
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  scope="${FORGE_CAPACITY_SCOPE:-${REPO%%/*}}"
  observation=$(mktemp)

  while true; do
    if [[ "$force_live" != "true" ]] && curl -sf \
        -H "Authorization: token ${GH_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        "${API}/repos/${REPO}/actions/variables/FORGE_CAPACITY_GITHUB" \
        | python3 -c "import json,sys; value=json.load(sys.stdin).get('value',''); json.loads(value); print(value)" \
        >"$observation" 2>/dev/null; then
      info "Using cached managed-estate capacity snapshot"
    elif ! python3 "${script_dir}/forge-capacity-observe.py" \
        --platform github --scope "$scope" \
        --registry "${script_dir}/../config/template-consumers.yml" >"$observation"; then
      if [[ "$FORGE_CAPACITY_REQUIRED" == "true" ]]; then
        rm -f "$observation"
        fail "Runner-capacity observation unavailable and FORGE_CAPACITY_REQUIRED=true"
      fi
      info "Runner-capacity observation unavailable — proceeding with GitHub's native queue"
      rm -f "$observation"
      return 0
    fi

    if decision=$(python3 "${script_dir}/forge-capacity-manager.py" \
        --platform github admit --observation "$observation" \
        --priority "$DISPATCH_PRIORITY" --slots "$DISPATCH_CAPACITY_SLOTS" --dry-run); then
      rc=0
    else
      rc=$?
    fi
    if [[ $rc -eq 0 ]]; then
      info "Capacity admitted: $(python3 -c "import json,sys; d=json.load(sys.stdin); c=d['capacity']; print(f\"{c['running']}/{c['total']} running, {c['queued']} queued, priority {d['priority']}, reserving ${DISPATCH_CAPACITY_SLOTS} slot(s)\")" <<<"$decision")"
      rm -f "$observation"
      return 0
    fi
    if [[ $rc -ne 3 ]]; then
      rm -f "$observation"
      fail "Runner-capacity admission failed: ${decision:-no decision}"
    fi
    if (( elapsed >= DISPATCH_CAPACITY_WAIT )); then
      rm -f "$observation"
      fail "Runner capacity remained unavailable for ${DISPATCH_CAPACITY_WAIT}s: ${decision}" 3
    fi
    # A deferred cached snapshot cannot become more accurate by rereading the
    # same variable. Switch to a live managed-registry scan for recovery.
    force_live=true
    info "Capacity deferred: $(python3 -c "import json,sys; d=json.load(sys.stdin); c=d['capacity']; print(f\"{d['reason']} ({c['running']}/{c['total']} running, {c['queued']} queued)\")" <<<"$decision") — retrying in ${DISPATCH_CAPACITY_POLL}s"
    sleep "$DISPATCH_CAPACITY_POLL"
    elapsed=$(( elapsed + DISPATCH_CAPACITY_POLL ))
  done
}

_drain_managed_estate() {
  [[ "$DISPATCH_ESTATE_DRAIN" == "true" ]] || return 0

  local script_dir scope marker_id marker_file now last
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  scope="${FORGE_CAPACITY_SCOPE:-${REPO%%/*}}"
  if [[ ! -f "${script_dir}/managed-estate-queue-drain.py" ]]; then
    info "Managed-estate drain unavailable — continuing without it"
    return 0
  fi

  marker_id="${GITHUB_RUN_ID:-${REPO//\//-}}"
  marker_file="${RUNNER_TEMP:-/tmp}/fsa-estate-drain-${marker_id}.stamp"
  now=$(date +%s)
  if [[ -f "$marker_file" ]]; then
    last=$(head -n 1 "$marker_file" 2>/dev/null || echo 0)
    if [[ "$last" =~ ^[0-9]+$ ]] && (( now - last < DISPATCH_ESTATE_DRAIN_INTERVAL )); then
      info "Managed-estate drain ran recently for parent ${marker_id}; skipping repeat scan"
      return 0
    fi
  fi

  local -a drain_args=(
    --platform github
    --registry "${script_dir}/../config/template-consumers.yml"
    --tiers "${script_dir}/../config/workflow-priority-tiers.yml"
    --scope "$scope"
  )
  if [[ -n "${GITHUB_RUN_ID:-}" ]]; then
    drain_args+=(--protect-run-id "$GITHUB_RUN_ID")
  fi

  info "Draining managed-consumer fallback runs before dispatch..."
  if ! python3 "${script_dir}/managed-estate-queue-drain.py" "${drain_args[@]}"; then
    info "Managed-estate drain observation unavailable or incomplete — continuing with capacity admission"
  fi
  printf '%s\n' "$now" > "$marker_file"
}

_cancel_timed_out_run() {
  [[ "$DISPATCH_CANCEL_ON_TIMEOUT" == "true" ]] || {
    info "Timeout cancellation disabled; run ${RUN_ID} remains active"
    return 0
  }
  if [[ "$RUN_OWNED" != "true" && "$DISPATCH_CANCEL_ADOPTED_ON_TIMEOUT" != "true" ]]; then
    info "Timed-out run ${RUN_ID} was adopted, not dispatched by this invocation; leaving it active"
    return 0
  fi

  local response_file http_code response
  response_file=$(mktemp)
  http_code=$(curl -sS -o "$response_file" -w "%{http_code}" \
    -X POST \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: ${API_VERSION}" \
    "${API}/repos/${REPO}/actions/runs/${RUN_ID}/cancel" 2>/dev/null || true)
  response=$(head -c 200 "$response_file" 2>/dev/null || true)
  rm -f "$response_file"

  if [[ "$http_code" == "202" ]]; then
    ok "Cancellation requested for timed-out run ${RUN_ID}"
  else
    info "Cancellation request for timed-out run ${RUN_ID} returned HTTP ${http_code:-000}${response:+: ${response}}"
  fi
}

RUN_ID=""
RUN_OWNED="false"
_adopted=""
_inputs_are_empty=$(python3 -c "import json,sys; print('true' if not json.loads(sys.argv[1]) else 'false')" "$INPUTS")
# The run-list API does not expose workflow_dispatch inputs. Adopting an active
# run is therefore safe only for an input-less dispatch. Input-bearing stages
# (including repeated reconcile/integrity stages) always dispatch a new run and
# use the exact run ID returned by the current API.
if [[ "$_inputs_are_empty" == "true" ]]; then
  for _status in in_progress queued; do
    _found=$(_find_active_run "$_status" "$BEFORE_TS" "$ADOPT_WINDOW_SEC")
    if [[ -n "$_found" ]]; then
      RUN_ID="$_found"
      _adopted="$_status"
      break
    fi
  done
else
  info "Inputs supplied — skipping active-run adoption because run inputs are not exposed by the list API"
fi

if [[ -n "$RUN_ID" ]]; then
  info "Found existing ${_adopted} run ${RUN_ID} for ${WORKFLOW} within adopt window (${ADOPT_WINDOW_SEC}s) — adopting instead of dispatching a duplicate"
else

  # Clear redundant managed-consumer fallback work before adding another
  # child run. Observation failures are non-fatal; capacity admission below
  # still provides the final guard against oversubscribing the hosted pool.
  _drain_managed_estate

  # Prevent central orchestrators from adding more child runs while the shared
  # hosted-runner pool is saturated. Existing matching runs are adopted above
  # without admission because they do not add load.
  _wait_for_capacity

  # ── Quota pre-check ─────────────────────────────────────────────────────────
  # Wait for quota to recover before attempting dispatch. Each failed attempt
  # costs 1 REST call; burning 10 retries on a quota-exhausted token wastes
  # the first calls after reset and delays the actual dispatch.
  _MAX_QUOTA_WAIT=3900  # 65 min — covers one full reset window
  _quota_elapsed=0
  while true; do
    _remaining=$(curl -sf \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "X-GitHub-Api-Version: ${API_VERSION}" \
      "https://api.github.com/rate_limit" \
      | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['resources']['core']['remaining'])" 2>/dev/null || echo "0")
    if [[ "${_remaining:-0}" -ge "$_DISPATCH_QUOTA_FLOOR" ]]; then
      info "Quota OK (${_remaining} remaining, need ${_DISPATCH_QUOTA_FLOOR}) — proceeding with dispatch"
      break
    fi
    _reset_in=$(curl -sf \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "X-GitHub-Api-Version: ${API_VERSION}" \
      "https://api.github.com/rate_limit" \
      | python3 -c "import json,sys,time; d=json.load(sys.stdin); print(max(0,d['resources']['core']['reset']-int(time.time())+5))" 2>/dev/null || echo "60")
    [[ "${_reset_in:-0}" -gt 0 ]] || _reset_in=60
    _wait=$(( _reset_in > _MAX_QUOTA_WAIT - _quota_elapsed ? _MAX_QUOTA_WAIT - _quota_elapsed : _reset_in ))
    info "Quota too low (${_remaining:-0} < ${_DISPATCH_QUOTA_FLOOR}) — waiting ${_wait}s for reset before dispatch"
    sleep "${_wait}"
    _quota_elapsed=$(( _quota_elapsed + _wait ))
    [[ $_quota_elapsed -ge $_MAX_QUOTA_WAIT ]] && { fail "Quota did not recover after ${_MAX_QUOTA_WAIT}s — aborting dispatch"; }
  done

  # Snapshot existing workflow-dispatch run IDs immediately before the POST.
  # This lets the legacy 204 fallback exclude pre-existing runs even when their
  # created_at value falls in the same whole second as BEFORE_TS.
  _KNOWN_RUN_IDS=$(curl -sf \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: ${API_VERSION}" \
    "${API}/repos/${REPO}/actions/workflows/${WORKFLOW}/runs?event=workflow_dispatch&branch=main&per_page=100" \
    | python3 -c "import json,sys; print(','.join(str(r['id']) for r in json.load(sys.stdin).get('workflow_runs', [])))" \
    2>/dev/null || echo "")

  # ── Dispatch with retry ───────────────────────────────────────────────────
  # Retries handle three transient 400 cases:
  #   1. New commit being indexed on the target ref (~10-120s window)
  #   2. Concurrency group mid-cancellation of an in_progress run (~30-60s)
  #   3. GitHub Actions infra briefly unavailable (rare)
  # On 403 (quota exhausted mid-loop): sleep until X-RateLimit-Reset then retry.
  # Quota-wait sleeps do not count against the 10-attempt cap; hard cap of 3
  # quota resets prevents infinite loops on a permanently exhausted token.
  HTTP_CODE="000"
  _quota_waits=0
  for _attempt in 1 2 3 4 5 6 7 8 9 10; do
    # Capture HTTP status and headers cleanly.
    # Do NOT use || echo "000" inside $(...) — curl writes the http_code via -w
    # before exiting non-zero, so the fallback echo appends to it, producing
    # values like "400000".
    _HTTP_TMP=$(mktemp)
    _HDR_TMP=$(mktemp)
    _BODY_TMP=$(mktemp)
    # Write the already-validated JSON body without shell interpolation.
    _build_dispatch_body > "${_BODY_TMP}"
    HTTP_CODE=$(curl -s -w "%{http_code}" -o "$_HTTP_TMP" -D "$_HDR_TMP" \
      -X POST \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: ${API_VERSION}" \
      -H "Content-Type: application/json" \
      "${API}/repos/${REPO}/actions/workflows/${WORKFLOW}/dispatches" \
      -d "@${_BODY_TMP}" 2>/dev/null)
    rm -f "${_BODY_TMP}"
    HTTP_CODE="${HTTP_CODE:-000}"

    if [[ "$HTTP_CODE" == "200" ]]; then
      RUN_ID=$(python3 -c "import json,sys; value=json.load(sys.stdin).get('workflow_run_id'); print(value if isinstance(value,int) and value > 0 else '')" < "$_HTTP_TMP" 2>/dev/null || echo "")
      if [[ -z "$RUN_ID" ]]; then
        _body=$(head -c 200 "$_HTTP_TMP" 2>/dev/null || true)
        rm -f "$_HTTP_TMP" "$_HDR_TMP"
        fail "Dispatch returned HTTP 200 without a valid workflow_run_id: ${_body}"
      fi
      rm -f "$_HTTP_TMP" "$_HDR_TMP"
      info "Dispatched exact run ${RUN_ID}."
      break
    elif [[ "$HTTP_CODE" == "204" ]]; then
      rm -f "$_HTTP_TMP" "$_HDR_TMP"
      break
    fi

    # Log the response body
    _body=$(cat "$_HTTP_TMP" 2>/dev/null || echo "")
    _msg=$(echo "$_body" | python3 -c "
import json,sys
d=json.load(sys.stdin)
msg=d.get('message','')
errs=d.get('errors','')
url=d.get('documentation_url','')
parts=[msg]
if errs: parts.append(f'errors={errs}')
if url: parts.append(f'docs={url}')
print(' | '.join(p for p in parts if p))
" 2>/dev/null || echo "$_body" | head -c 200)
    rm -f "$_HTTP_TMP"

    if [[ "$HTTP_CODE" == "403" || "$HTTP_CODE" == "429" ]]; then
      # Quota exhausted mid-loop — read reset time from headers and wait
      _reset=$(grep -i "x-ratelimit-reset:" "$_HDR_TMP" 2>/dev/null \
        | tr -d '\r' | awk '{print $2}' || echo "")
      rm -f "$_HDR_TMP"
      _now=$(date +%s)
      _wait=60
      if [[ -n "$_reset" && "$_reset" -gt "$_now" ]]; then
        _wait=$(( _reset - _now + 10 ))
      fi
      info "Dispatch attempt ${_attempt} failed (HTTP ${HTTP_CODE} — quota) — waiting ${_wait}s for reset..."
      [[ -n "$_msg" ]] && info "  Response: ${_msg}"
      sleep "$_wait"
      # Don't count quota-wait attempts against the retry cap — decrement so
      # the next iteration reuses the same attempt number.
      # Hard cap: bail after 3 quota resets to avoid infinite loops on a
      # permanently exhausted or revoked token.
      (( _quota_waits++ )) || true
      if (( _quota_waits >= 3 )); then
        info "Quota reset waited ${_quota_waits} times — giving up."
        break
      fi
      (( _attempt-- )) || true
    else
      rm -f "$_HDR_TMP"
      _sleep=$( [[ $_attempt -ge 5 ]] && echo 30 || echo 20 )
      info "Dispatch attempt ${_attempt} failed (HTTP ${HTTP_CODE}) — retrying in ${_sleep}s..."
      [[ -n "$_msg" ]] && info "  Response: ${_msg}"
      sleep "$_sleep"
    fi
  done

  if [[ "$HTTP_CODE" != "200" && "$HTTP_CODE" != "204" ]]; then
    fail "Dispatch failed after 10 attempts (HTTP ${HTTP_CODE})"
  fi

  if [[ -z "$RUN_ID" ]]; then
    info "Legacy HTTP 204 dispatch accepted. Waiting for its run to appear..."
    sleep 8

    # Legacy API responses do not identify the run. Restrict correlation to
    # workflow_dispatch runs on the requested branch and fail closed if more
    # than one candidate exists, rather than adopting a run with other inputs.
    ATTEMPTS=0
    while [[ -z "$RUN_ID" && $ATTEMPTS -lt 15 ]]; do
      _candidates=$(curl -sf \
        -H "Authorization: token ${GH_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: ${API_VERSION}" \
        "${API}/repos/${REPO}/actions/workflows/${WORKFLOW}/runs?event=workflow_dispatch&branch=main&per_page=10" \
        | python3 -c "
import json, sys
from datetime import datetime
data = json.load(sys.stdin)
before = datetime.fromisoformat('${BEFORE_TS}'.replace('Z','+00:00'))
known = {int(value) for value in '${_KNOWN_RUN_IDS}'.split(',') if value}
for r in data.get('workflow_runs', []):
    created = datetime.fromisoformat(r['created_at'].replace('Z','+00:00'))
    if (r.get('event') == 'workflow_dispatch'
            and r.get('head_branch') == 'main'
            and r['id'] not in known
            and created >= before):
        print(r['id'])
" 2>/dev/null || echo "")
      _candidate_count=$(printf '%s\n' "$_candidates" | sed '/^$/d' | wc -l | tr -d ' ')
      if [[ "$_candidate_count" -eq 1 ]]; then
        RUN_ID="$_candidates"
      elif [[ "$_candidate_count" -gt 1 ]]; then
        fail "Legacy dispatch correlation is ambiguous (${_candidate_count} new runs); refusing to adopt the wrong run"
      fi
      (( ATTEMPTS++ )) || true
      [[ -z "$RUN_ID" ]] && sleep 5
    done

    if [[ -z "$RUN_ID" ]]; then
      fail "Could not find run after legacy dispatch"
    fi
  fi

  # Both an exact HTTP 200 ID and an unambiguous HTTP 204 correlation identify
  # a run created by this invocation. Adopted runs intentionally remain false.
  RUN_OWNED="true"

fi # end adopt-or-dispatch

if [[ "$DISPATCH_NO_WAIT" == "true" ]]; then
  ok "Run ID: ${RUN_ID} — accepted without waiting for completion"
  exit 0
fi

# ── Poll for completion ───────────────────────────────────────────────────────
info "Run ID: ${RUN_ID} — polling for completion (timeout: ${TIMEOUT_MIN}m)..."
DEADLINE=$(( $(date +%s) + TIMEOUT_MIN * 60 ))

while true; do
  if [[ $(date +%s) -gt $DEADLINE ]]; then
    _cancel_timed_out_run
    fail "Timed out after ${TIMEOUT_MIN}m waiting for ${WORKFLOW}"
  fi

  RUN_JSON=$(curl -sf \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: ${API_VERSION}" \
    "${API}/repos/${REPO}/actions/runs/${RUN_ID}" 2>/dev/null || echo "{}")

  STATUS=$(echo "$RUN_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
  CONCLUSION=$(echo "$RUN_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('conclusion',''))" 2>/dev/null || echo "")

  if [[ "$STATUS" == "completed" ]]; then
    case "$CONCLUSION" in
      success|skipped)
        ok "${WORKFLOW} completed: ${CONCLUSION}"
        exit 0
        ;;
      cancelled)
        if (( DISPATCH_CANCEL_RETRIES > 0 )); then
          info "${WORKFLOW} was cancelled — re-dispatching (${DISPATCH_CANCEL_RETRIES} retries remaining)"
          export DISPATCH_CANCEL_RETRIES=$(( DISPATCH_CANCEL_RETRIES - 1 ))
          exec bash "$0" "$WORKFLOW" "$TIMEOUT_MIN" "$INPUTS"
        fi
        if [[ "$DISPATCH_CANCEL_EXIT_CODE" == "0" ]]; then
          info "${WORKFLOW} was cancelled — treating it as a skipped stage"
          exit 0
        fi
        # Exit 2 so retrying callers can distinguish it from real failures.
        fail "${WORKFLOW} was cancelled (exit 2)" 2
        ;;
      *)
        fail "${WORKFLOW} completed with: ${CONCLUSION}"
        ;;
    esac
  fi

  # Empty status means GitHub hasn't assigned a runner yet — keep waiting
  STATUS_DISPLAY="${STATUS:-waiting for runner}"
  info "... ${STATUS_DISPLAY} at $(_now_dual) (checking again in ${DISPATCH_COMPLETION_POLL}s)"
  sleep "$DISPATCH_COMPLETION_POLL"
done
