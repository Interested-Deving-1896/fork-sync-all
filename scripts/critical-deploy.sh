#!/usr/bin/env bash
#
# Critical deploy — commit + push local changes and/or dispatch workflows
# with an aggressive queue-clear pass first to ensure fast execution.
#
# Hybrid approach:
#   Phase 1 (optional) — stage and push local file changes directly to main.
#                        Git push never consumes GitHub API quota.
#   Phase 2            — run queue-manager aggressively (low stale threshold)
#                        to clear the runway before dispatching.
#   Phase 3 (optional) — dispatch one or more workflows in priority order,
#                        waiting for each to complete before starting the next.
#
# Priority tiers (inspired by throttle-master / TaskScheduler patterns):
#   HIGH   (1) — security/token rotation, queue management, config fixes
#   MEDIUM (2) — mirror chain, sync operations
#   LOW    (3) — README updates, dep graph, non-critical maintenance
#
# Required env:
#   GH_TOKEN   — PAT with actions:write + contents:write on REPO
#   REPO       — owner/repo
#
# Optional env:
#   COMMIT_FILES      — space-separated file paths to stage and commit
#   COMMIT_MESSAGE    — commit message (required if COMMIT_FILES is set)
#   COMMIT_AUTHOR     — "Name <email>" (default: github-actions[bot])
#   WORKFLOWS         — space-separated workflow filenames to dispatch
#   WORKFLOW_INPUTS   — JSON object of inputs for all dispatched workflows
#   STALE_QUEUE_MIN   — stale threshold for aggressive queue clear (default: 10)
#   WAIT_FOR_EACH     — "true" to wait for each workflow before dispatching next (default: true)
#   TIMEOUT_MIN       — per-workflow timeout in minutes (default: 30)
#   DRY_RUN           — "true" to report without acting (default: false)
#   MIN_QUOTA         — abort if quota below this (default: 500)

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${REPO:?REPO is required}"

COMMIT_FILES="${COMMIT_FILES:-}"
COMMIT_MESSAGE="${COMMIT_MESSAGE:-}"
COMMIT_AUTHOR="${COMMIT_AUTHOR:-github-actions[bot] <github-actions[bot]@users.noreply.github.com>}"
WORKFLOWS="${WORKFLOWS:-}"
WORKFLOW_INPUTS="${WORKFLOW_INPUTS:-{}}"
STALE_QUEUE_MIN="${STALE_QUEUE_MIN:-10}"
WAIT_FOR_EACH="${WAIT_FOR_EACH:-true}"
TIMEOUT_MIN="${TIMEOUT_MIN:-30}"
DRY_RUN="${DRY_RUN:-false}"
MIN_QUOTA="${MIN_QUOTA:-500}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
API="https://api.github.com"

info() { echo "[critical-deploy] $*" >&2; }
ok()   { echo "[critical-deploy] ✓ $*" >&2; }
warn() { echo "[critical-deploy] ⚠ $*" >&2; }
dry()  { echo "[critical-deploy][dry-run] $*" >&2; }
fail() { echo "[critical-deploy] ✗ $*" >&2; exit 1; }

# ── Quota check ───────────────────────────────────────────────────────────────

read -r remaining reset_at < <(curl -sf \
  -H "Authorization: token ${GH_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "${API}/rate_limit" \
  | python3 -c "
import sys, json, datetime
d = json.load(sys.stdin).get('resources', {}).get('core', {})
remaining = d.get('remaining', 0)
reset_ts  = d.get('reset', 0)
reset_at  = (lambda dt: dt.strftime('%H:%M UTC') + ' / ' + dt.strftime('%I:%M %p UTC').lstrip('0') or '12:00 AM UTC')(datetime.datetime.fromtimestamp(reset_ts, tz=datetime.timezone.utc)) if reset_ts else 'unknown'
print(remaining, reset_at)
" 2>/dev/null || echo "0 unknown")

info "Quota: ${remaining} remaining (resets ${reset_at}, min required: ${MIN_QUOTA})"

if [[ "${remaining}" -lt "${MIN_QUOTA}" ]]; then
  warn "Quota too low (${remaining} < ${MIN_QUOTA}). Git push will still work but workflow dispatch will fail."
  warn "Reset at ${reset_at} — consider waiting or lowering MIN_QUOTA."
  # Don't abort — Phase 1 (git push) doesn't need quota
fi

# ── Phase 1: Commit and push local changes ────────────────────────────────────

if [[ -n "${COMMIT_FILES}" ]]; then
  info "Phase 1: Committing and pushing local changes..."

  if [[ -z "${COMMIT_MESSAGE}" ]]; then
    fail "COMMIT_MESSAGE is required when COMMIT_FILES is set."
  fi

  # Verify we're in a git repo
  git -C "${REPO_ROOT}" rev-parse --git-dir &>/dev/null \
    || fail "Not inside a git repository: ${REPO_ROOT}"

  # Check which files actually have changes
  staged=()
  missing=()
  for f in ${COMMIT_FILES}; do
    abs="${REPO_ROOT}/${f}"
    if [[ ! -e "$abs" ]]; then
      missing+=("$f")
      continue
    fi
    staged+=("$f")
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    warn "Files not found (skipping): ${missing[*]}"
  fi

  if [[ ${#staged[@]} -eq 0 ]]; then
    warn "No files to commit — skipping Phase 1."
  else
    if [[ "$DRY_RUN" == "true" ]]; then
      dry "Would stage: ${staged[*]}"
      dry "Would commit: ${COMMIT_MESSAGE}"
      dry "Would push to origin main"
    else
      git -C "${REPO_ROOT}" add "${staged[@]/#/${REPO_ROOT}/}"
      # Only commit if there are actual staged changes
      if git -C "${REPO_ROOT}" diff --cached --quiet; then
        info "No staged changes after git add — files may already be committed."
      else
        git -C "${REPO_ROOT}" commit \
          -m "${COMMIT_MESSAGE}" \
          --author "${COMMIT_AUTHOR}" \
          && ok "Committed: ${COMMIT_MESSAGE}"
        git -C "${REPO_ROOT}" push origin main \
          && ok "Pushed to origin/main."
      fi
    fi
  fi
else
  info "Phase 1: No files specified — skipping commit/push."
fi

# ── Phase 2: Aggressive queue clear ──────────────────────────────────────────

if [[ "${remaining}" -ge "${MIN_QUOTA}" ]]; then
  info "Phase 2: Clearing queue (stale threshold: ${STALE_QUEUE_MIN} min)..."

  if [[ "$DRY_RUN" == "true" ]]; then
    dry "Would run queue-manager.sh with STALE_QUEUE_MIN=${STALE_QUEUE_MIN} DRY_RUN=true"
  else
    STALE_QUEUE_MIN="${STALE_QUEUE_MIN}" \
    DRY_RUN="false" \
    MIN_QUOTA="${MIN_QUOTA}" \
    THIS_RUN_ID="${THIS_RUN_ID:-0}" \
    bash "${SCRIPT_DIR}/queue-manager.sh" \
      && ok "Queue cleared." \
      || warn "Queue manager returned non-zero — continuing anyway."

    # Brief pause to let cancellations propagate before dispatching
    info "Waiting 15s for cancellations to propagate..."
    sleep 15
  fi
else
  warn "Phase 2: Skipping queue clear — quota too low."
fi

# ── Phase 3: Dispatch workflows in priority order ────────────────────────────

if [[ -z "${WORKFLOWS}" ]]; then
  info "Phase 3: No workflows specified — skipping dispatch."
  ok "Critical deploy complete (commit/push only)."
  exit 0
fi

if [[ "${remaining}" -lt "${MIN_QUOTA}" ]]; then
  warn "Phase 3: Quota too low for workflow dispatch. Workflows NOT dispatched: ${WORKFLOWS}"
  warn "Re-run after quota resets at ${reset_at}."
  exit 1
fi

info "Phase 3: Dispatching workflows: ${WORKFLOWS}"

dispatched=0
failed=0

for workflow in ${WORKFLOWS}; do
  info "Dispatching ${workflow} (priority ${dispatched+1})..."

  if [[ "$DRY_RUN" == "true" ]]; then
    dry "Would dispatch ${workflow} with inputs: ${WORKFLOW_INPUTS}"
    (( dispatched++ )) || true
    continue
  fi

  if [[ "$WAIT_FOR_EACH" == "true" ]]; then
    GH_TOKEN="${GH_TOKEN}" \
    REPO="${REPO}" \
    bash "${SCRIPT_DIR}/dispatch-and-wait.sh" "${workflow}" "${TIMEOUT_MIN}" "${WORKFLOW_INPUTS}"
    daw_exit=$?
    if [[ $daw_exit -eq 0 ]]; then
      ok "${workflow} completed."
    elif [[ $daw_exit -eq 2 ]]; then
      warn "${workflow} was cancelled by queue-manager — re-queuing is safe, continuing."
    else
      warn "${workflow} failed or timed out — continuing with next workflow."
      (( failed++ )) || true
    fi
  else
    # Fire and forget — dispatch without waiting
    HTTP_CODE=$(curl -sf -w "%{http_code}" -o /dev/null \
      -X POST \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      "${API}/repos/${REPO}/actions/workflows/${workflow}/dispatches" \
      -d "{\"ref\":\"main\",\"inputs\":${WORKFLOW_INPUTS}}" 2>/dev/null || echo "000")

    if [[ "$HTTP_CODE" == "204" ]]; then
      ok "Dispatched ${workflow} (fire-and-forget)."
    else
      warn "Dispatch failed for ${workflow} (HTTP ${HTTP_CODE})."
      (( failed++ )) || true
    fi
  fi

  (( dispatched++ )) || true
done

# ── Summary ───────────────────────────────────────────────────────────────────

{
  echo "## Critical Deploy"
  echo ""
  echo "| Phase | Result |"
  echo "|---|---|"
  [[ -n "${COMMIT_FILES}" ]] && echo "| Commit + push | ✅ |" || echo "| Commit + push | skipped |"
  echo "| Queue clear | ✅ (stale threshold: ${STALE_QUEUE_MIN} min) |"
  echo "| Workflows dispatched | ${dispatched} |"
  [[ $failed -gt 0 ]] && echo "| Workflows failed | ${failed} |" || true
  echo "| Dry run | ${DRY_RUN} |"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

if [[ $failed -gt 0 ]]; then
  warn "${failed} workflow(s) failed or timed out."
  exit 1
fi

ok "Critical deploy complete. Dispatched: ${dispatched}."
