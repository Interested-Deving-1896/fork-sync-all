#!/usr/bin/env bash
#
# Dispatches a workflow and polls until it completes.
#
# Usage: dispatch-and-wait.sh <workflow_file> [timeout_minutes] [inputs_json]
#
# Required env vars:
#   GH_TOKEN  — PAT with actions:write
#   REPO      — owner/repo (e.g. Interested-Deving-1896/fork-sync-all)
#
# Exit codes:
#   0 — workflow completed with success or skipped
#   1 — dispatch failed, timed out, or workflow concluded with failure

set -uo pipefail

WORKFLOW="${1:?workflow file required}"
TIMEOUT_MIN="${2:-90}"
INPUTS="${3:-{}}"
API="https://api.github.com"

_TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/includes" 2>/dev/null && pwd || echo "")"

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

# Record time before dispatch so we can find the new run (ISO — machine-facing)
BEFORE_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

info "Dispatching ${WORKFLOW}..."

# ── Quota pre-check ───────────────────────────────────────────────────────────
# Wait for quota to recover before attempting dispatch. Each failed attempt
# costs 1 REST call; burning 10 retries on a quota-exhausted token wastes
# the first calls after reset and delays the actual dispatch.
_MAX_QUOTA_WAIT=3900  # 65 min — covers one full reset window
_quota_elapsed=0
while true; do
  _remaining=$(curl -sf \
    -H "Authorization: token ${GH_TOKEN}" \
    "https://api.github.com/rate_limit" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['resources']['core']['remaining'])" 2>/dev/null || echo "0")
  if [[ "${_remaining:-0}" -ge 50 ]]; then
    info "Quota OK (${_remaining} remaining) — proceeding with dispatch"
    break
  fi
  _reset_in=$(curl -sf \
    -H "Authorization: token ${GH_TOKEN}" \
    "https://api.github.com/rate_limit" \
    | python3 -c "import json,sys,time; d=json.load(sys.stdin); print(max(0,d['resources']['core']['reset']-int(time.time())+5))" 2>/dev/null || echo "60")
  _wait=$(( _reset_in > _MAX_QUOTA_WAIT ? _MAX_QUOTA_WAIT : _reset_in ))
  info "Quota too low (${_remaining:-0}) — waiting ${_wait}s for reset before dispatch"
  sleep "${_wait}"
  _quota_elapsed=$(( _quota_elapsed + _wait ))
  [[ $_quota_elapsed -ge $_MAX_QUOTA_WAIT ]] && { fail "Quota did not recover after ${_MAX_QUOTA_WAIT}s — aborting dispatch"; }
done

# ── Dispatch with retry ───────────────────────────────────────────────────────
# Retries handle three transient 400 cases:
#   1. New commit being indexed on the target ref (~10-120s window)
#   2. Concurrency group mid-cancellation of an in_progress run (~30-60s)
#   3. GitHub Actions infra briefly unavailable (rare)
# On 403 (quota exhausted mid-loop): sleep until X-RateLimit-Reset then retry.
HTTP_CODE="000"
for _attempt in 1 2 3 4 5 6 7 8 9 10; do
  # Capture HTTP status and headers cleanly.
  # Do NOT use || echo "000" inside $(...) — curl writes the http_code via -w
  # before exiting non-zero, so the fallback echo appends to it, producing
  # values like "400000".
  _HTTP_TMP=$(mktemp)
  _HDR_TMP=$(mktemp)
  _BODY="{\"ref\":\"main\",\"inputs\":${INPUTS}}"
  if [[ $_attempt -eq 1 ]]; then
    info "DEBUG INPUTS value: ${INPUTS}"
    info "DEBUG INPUTS hex: $(printf '%s' "${INPUTS}" | xxd -p | tr -d '\n')"
    info "DEBUG dispatch body: ${_BODY}"
  fi
  HTTP_CODE=$(curl -s -w "%{http_code}" -o "$_HTTP_TMP" -D "$_HDR_TMP" \
    -X POST \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    "${API}/repos/${REPO}/actions/workflows/${WORKFLOW}/dispatches" \
    -d "${_BODY}" 2>/dev/null)
  HTTP_CODE="${HTTP_CODE:-000}"

  if [[ "$HTTP_CODE" == "204" ]]; then
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
  else
    rm -f "$_HDR_TMP"
    _sleep=$( [[ $_attempt -ge 5 ]] && echo 30 || echo 20 )
    info "Dispatch attempt ${_attempt} failed (HTTP ${HTTP_CODE}) — retrying in ${_sleep}s..."
    [[ -n "$_msg" ]] && info "  Response: ${_msg}"
    sleep "$_sleep"
  fi
done

if [[ "$HTTP_CODE" != "204" ]]; then
  fail "Dispatch failed after 10 attempts (HTTP ${HTTP_CODE})"
fi

info "Dispatched. Waiting for run to appear..."
sleep 8

# Find the run created after BEFORE_TS
RUN_ID=""
ATTEMPTS=0
while [[ -z "$RUN_ID" && $ATTEMPTS -lt 15 ]]; do
  RUN_ID=$(curl -sf \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${API}/repos/${REPO}/actions/workflows/${WORKFLOW}/runs?per_page=5" \
    | python3 -c "
import json, sys
from datetime import datetime, timezone
data = json.load(sys.stdin)
before = datetime.fromisoformat('${BEFORE_TS}'.replace('Z','+00:00'))
for r in data.get('workflow_runs', []):
    created = datetime.fromisoformat(r['created_at'].replace('Z','+00:00'))
    if created >= before:
        print(r['id'])
        break
" 2>/dev/null || echo "")
  (( ATTEMPTS++ )) || true
  [[ -z "$RUN_ID" ]] && sleep 5
done

if [[ -z "$RUN_ID" ]]; then
  fail "Could not find run after dispatch"
fi

info "Run ID: ${RUN_ID} — polling for completion (timeout: ${TIMEOUT_MIN}m)..."
DEADLINE=$(( $(date +%s) + TIMEOUT_MIN * 60 ))

while true; do
  if [[ $(date +%s) -gt $DEADLINE ]]; then
    fail "Timed out after ${TIMEOUT_MIN}m waiting for ${WORKFLOW}"
  fi

  RUN_JSON=$(curl -sf \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
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
        # Cancelled by queue-manager or manually — not a workflow failure.
        # Exit 2 so callers can distinguish cancellation from real failures.
        fail "${WORKFLOW} was cancelled (exit 2)" 2
        ;;
      *)
        fail "${WORKFLOW} completed with: ${CONCLUSION}"
        ;;
    esac
  fi

  # Empty status means GitHub hasn't assigned a runner yet — keep waiting
  STATUS_DISPLAY="${STATUS:-waiting for runner}"
  info "... ${STATUS_DISPLAY} at $(_now_dual) (checking again in 30s)"
  sleep 30
done
