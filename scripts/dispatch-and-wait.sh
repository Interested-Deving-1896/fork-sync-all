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

info() { echo "[dispatch-wait] $*" >&2; }
ok()   { echo "[dispatch-wait] ✓ $*" >&2; }
fail() { echo "[dispatch-wait] ✗ $1" >&2; exit "${2:-1}"; }

# Record time before dispatch so we can find the new run
BEFORE_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

info "Dispatching ${WORKFLOW}..."

# Retry up to 3 times — the dispatch API occasionally returns 400 transiently
# (e.g. during a commit index window). A single failure should not abort the caller.
HTTP_CODE="000"
for _attempt in 1 2 3; do
  HTTP_CODE=$(curl -sf -w "%{http_code}" -o /dev/null \
    -X POST \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${API}/repos/${REPO}/actions/workflows/${WORKFLOW}/dispatches" \
    -d "{\"ref\":\"main\",\"inputs\":${INPUTS}}" 2>/dev/null || echo "000")
  [[ "$HTTP_CODE" == "204" ]] && break
  info "Dispatch attempt ${_attempt} failed (HTTP ${HTTP_CODE}) — retrying in 10s..."
  sleep 10
done

if [[ "$HTTP_CODE" != "204" ]]; then
  fail "Dispatch failed after 3 attempts (HTTP ${HTTP_CODE})"
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
  info "... ${STATUS_DISPLAY} (checking again in 30s)"
  sleep 30
done
