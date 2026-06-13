#!/usr/bin/env bash
# scripts/includes/budget.sh — shared time-budget guard for long-running scripts
#
# Prevents GitHub Actions timeout kills mid-operation by checking elapsed time
# before each unit of work and exiting gracefully when the budget is nearly
# exhausted. Repos/items skipped due to budget are picked up on the next run.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/includes/budget.sh"
#   budget_init          # call once near the top of the script
#   budget_check LABEL   # call before each per-repo/per-item operation
#
# Environment:
#   BUDGET_MINUTES  — total allowed runtime in minutes (default: 55).
#                     Set to 0 to disable the guard entirely.
#                     Workflows should set this to (timeout-minutes - 5) to
#                     leave a safe margin for final reporting and cleanup.
#
# budget_check exits 0 (continue) or calls budget_exceeded (stop).
# Override budget_exceeded() in the calling script to customise behaviour
# (e.g. print a summary before exiting).
#
# Example:
#   budget_init
#   for repo in $repos; do
#     budget_check "$repo" || break
#     process "$repo"
#   done
#   budget_report

# ── State ─────────────────────────────────────────────────────────────────────
_BUDGET_START_TS=0
_BUDGET_SKIPPED=0
_BUDGET_LABEL="items"

budget_init() {
  _BUDGET_START_TS=$(date +%s)
  _BUDGET_SKIPPED=0
  local budget="${BUDGET_MINUTES:-55}"
  if (( budget == 0 )); then
    : # guard disabled — budget_check will always return 0
  else
    _budget_log "Budget: ${budget} min from now (stops with 2 min to spare)"
  fi
}

# budget_check LABEL
# Returns 0 if there is budget remaining, calls budget_exceeded otherwise.
# LABEL is used in log output only.
budget_check() {
  local label="${1:-item}"
  local budget="${BUDGET_MINUTES:-55}"
  (( budget == 0 )) && return 0   # guard disabled

  local now elapsed budget_secs remaining
  now=$(date +%s)
  elapsed=$(( now - _BUDGET_START_TS ))
  budget_secs=$(( budget * 60 ))
  # Reserve 2 min for final reporting / cleanup
  remaining=$(( budget_secs - elapsed - 120 ))

  if (( remaining <= 0 )); then
    (( _BUDGET_SKIPPED++ )) || true
    budget_exceeded "$label" "$elapsed" "$budget_secs"
    return 1
  fi
  return 0
}

# budget_report — print elapsed time and skipped count. Call at end of script.
budget_report() {
  local budget="${BUDGET_MINUTES:-55}"
  (( budget == 0 )) && return 0
  local elapsed=$(( $(date +%s) - _BUDGET_START_TS ))
  local mins=$(( elapsed / 60 ))
  local secs=$(( elapsed % 60 ))
  _budget_log "Elapsed: ${mins}m${secs}s / ${budget}m budget | budget-skipped: ${_BUDGET_SKIPPED}"
}

# budget_skipped — return the number of items skipped due to budget exhaustion.
budget_skipped() { echo "${_BUDGET_SKIPPED}"; }

# ── Overridable hook ──────────────────────────────────────────────────────────
# Called when budget is exhausted. Override in the calling script to print
# a summary or set exit codes before the loop breaks.
budget_exceeded() {
  local label="$1" elapsed="$2" budget_secs="$3"
  _budget_log "Budget exhausted at ${elapsed}s/${budget_secs}s — skipping '${label}' and remaining ${_BUDGET_LABEL}. Will resume on next run."
}

# ── Per-workflow quota cost lookup ───────────────────────────────────────────
# workflow_min_quota <workflow_name>
# Returns the min_quota for a workflow from config/workflow-quota-costs.yml.
# Falls back to 300 if the workflow is not listed or the config is missing.
#
# Usage (in a workflow pre-flight step):
#   source scripts/includes/budget.sh
#   min=$(workflow_min_quota "Mirror OSP → GitLab")
#   if [[ "$remaining" -lt "$min" ]]; then echo "skip=true"; fi
_BUDGET_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workflow_min_quota() {
  local name="$1"
  local config_path="${BUDGET_QUOTA_COSTS_CONFIG:-${_BUDGET_SCRIPT_DIR}/../../config/workflow-quota-costs.yml}"
  if [[ -f "$config_path" ]]; then
    python3 - "$name" "$config_path" <<'PYEOF' 2>/dev/null || echo "300"
import sys, yaml
name = sys.argv[1]
with open(sys.argv[2]) as f:
    data = yaml.safe_load(f)
for wf in (data.get('workflows') or []):
    if wf.get('name') == name:
        print(wf.get('min_quota', 300))
        sys.exit(0)
print(300)
PYEOF
  else
    echo "300"
  fi
}

# ── OSP-priority repo ordering ────────────────────────────────────────────────
# osp_priority_repos CONFIG_PATH ALL_REPOS_VAR
#
# Splits a space-separated repo list into two ordered groups:
#   1. OSP-bound repos (from config/gitlab-subgroups.yml) — processed first
#   2. Remaining repos — processed only if budget permits
#
# Prints the combined ordered list to stdout.
# Emits a separator line "---secondary---" between the two groups so callers
# can detect when the secondary pass begins and log accordingly.
#
# Usage:
#   ordered=$(osp_priority_repos "$OSP_REPOS_CONFIG" "$all_repos")
#   in_secondary=false
#   for repo in $ordered; do
#     [[ "$repo" == "---secondary---" ]] && { in_secondary=true; continue; }
#     $in_secondary && _budget_log "Secondary pass: $repo"
#     budget_check "$repo" || break
#     process "$repo"
#   done
osp_priority_repos() {
  local config_path="${1:-config/gitlab-subgroups.yml}"
  local all_repos="$2"

  local osp_repos=""
  if [[ -f "$config_path" ]]; then
    osp_repos=$(python3 - "$config_path" <<'PYEOF'
import sys, yaml
with open(sys.argv[1]) as f:
    config = yaml.safe_load(f)
for sg in (config.get("subgroups", {}) or {}).values():
    for repo in (sg.get("repos") or []):
        print(repo)
PYEOF
    ) 2>/dev/null || true
  fi

  # Emit OSP-bound repos first (intersection with all_repos)
  local printed_osp=""
  for repo in $osp_repos; do
    echo "$all_repos" | tr ' ' '\n' | grep -qx "$repo" || continue
    echo "$repo"
    printed_osp="$printed_osp $repo"
  done

  # Separator
  echo "---secondary---"

  # Emit remaining repos not in OSP-bound set
  for repo in $all_repos; do
    echo "$printed_osp" | tr ' ' '\n' | grep -qx "$repo" && continue
    echo "$repo"
  done
}

# ── Internal ──────────────────────────────────────────────────────────────────
_budget_log() { echo "[budget] $*" >&2; }
