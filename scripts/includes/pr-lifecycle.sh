#!/usr/bin/env bash
# scripts/includes/pr-lifecycle.sh — PR/MR lifecycle quota + queue guard
#
# Provides quota-aware lifecycle management for scripts that create or
# process PRs/MRs in a loop. When quota drops below the threshold mid-loop,
# the remaining work is written to a repo Actions variable and the calling
# workflow is re-dispatched so the run resumes after the quota reset.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/includes/pr-lifecycle.sh"
#
#   # Once, before the loop:
#   pr_lifecycle_init "ota-release.yml" "ota-deliver"
#
#   # Inside the loop, before each PR operation:
#   pr_lifecycle_defer "$repo"          # register item as pending
#   pr_lifecycle_check "$repo" || break # quota gate; breaks on exhaustion
#   # ... do PR work ...
#   pr_lifecycle_done "$repo"           # mark item complete
#
#   # After the loop:
#   pr_lifecycle_report
#
# Environment (all optional — defaults work for standard workflows):
#   PR_MIN_QUOTA        — minimum quota before deferring (default: 300)
#   PR_LIFECYCLE_DRY    — "true" to skip dispatch and var writes (default: false)
#   GH_TOKEN            — PAT with actions:write (required for dispatch)
#   REPO                — owner/repo of the calling workflow (default: GITHUB_REPOSITORY)
#
# Defer mechanism:
#   Remaining items are stored in repo Actions variable
#   PR_LIFECYCLE_DEFER_<KEY> (KEY = uppercased, non-alphanum → _).
#   On the next dispatch the calling workflow reads this variable and passes
#   it as RESUME_FROM env/input so the script can skip already-done items.
#   The variable is cleared when all items complete successfully.
#
# Guard against double-sourcing
[[ -n "${_PR_LIFECYCLE_LOADED:-}" ]] && return 0
_PR_LIFECYCLE_LOADED=1

# ── State ─────────────────────────────────────────────────────────────────────
_PRL_WORKFLOW_FILE=""   # e.g. "ota-release.yml"
_PRL_KEY=""             # sanitised key for the Actions variable
_PRL_PENDING=()         # items registered but not yet done
_PRL_DONE=()            # items completed this run
_PRL_DEFERRED=false     # set true when we trigger a defer
_PRL_MIN_QUOTA="${PR_MIN_QUOTA:-300}"
_PRL_DRY="${PR_LIFECYCLE_DRY:-false}"
_PRL_REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
_PRL_API="${API:-https://api.github.com}"

_prl_info() { echo "[pr-lifecycle] $*" >&2; }
_prl_warn() { echo "[pr-lifecycle] WARN: $*" >&2; }

# ── Quota helper ──────────────────────────────────────────────────────────────

_prl_quota_remaining() {
  curl -sf \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${_PRL_API}/rate_limit" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['resources']['core']['remaining'])" \
    2>/dev/null || echo 0
}

# ── Actions variable helpers ──────────────────────────────────────────────────

_prl_var_name() {
  # PR_LIFECYCLE_DEFER_OTA_DELIVER etc.
  echo "PR_LIFECYCLE_DEFER_${_PRL_KEY}"
}

_prl_set_var() {
  local var_name="$1" value="$2"
  [[ "$_PRL_DRY" == "true" ]] && { _prl_info "[dry] set var ${var_name}"; return 0; }
  [[ -z "$_PRL_REPO" ]] && { _prl_warn "REPO not set — cannot write Actions variable"; return 1; }

  local payload
  payload=$(python3 -c "import json,sys; print(json.dumps({'name':sys.argv[1],'value':sys.argv[2]}))" \
    "$var_name" "$value")

  local http_status
  http_status=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "${_PRL_API}/repos/${_PRL_REPO}/actions/variables" 2>/dev/null || echo "000")

  # 409 = already exists → PATCH instead
  if [[ "$http_status" == "409" ]]; then
    http_status=$(curl -s -o /dev/null -w "%{http_code}" \
      -X PATCH \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "${_PRL_API}/repos/${_PRL_REPO}/actions/variables/${var_name}" 2>/dev/null || echo "000")
  fi

  [[ "$http_status" =~ ^2 ]] || _prl_warn "Failed to set var ${var_name} (HTTP ${http_status})"
}

_prl_delete_var() {
  local var_name="$1"
  [[ "$_PRL_DRY" == "true" ]] && { _prl_info "[dry] delete var ${var_name}"; return 0; }
  [[ -z "$_PRL_REPO" ]] && return 0

  curl -s -o /dev/null \
    -X DELETE \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${_PRL_API}/repos/${_PRL_REPO}/actions/variables/${var_name}" 2>/dev/null || true
}

# ── Dispatch helper ───────────────────────────────────────────────────────────

_prl_dispatch() {
  local workflow_file="$1"
  [[ "$_PRL_DRY" == "true" ]] && { _prl_info "[dry] dispatch ${workflow_file}"; return 0; }
  [[ -z "$_PRL_REPO" ]] && { _prl_warn "REPO not set — cannot dispatch"; return 1; }

  local payload
  payload=$(python3 -c "import json; print(json.dumps({'ref':'main','inputs':{'resume_from':'deferred'}}))")

  local http_status
  http_status=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "${_PRL_API}/repos/${_PRL_REPO}/actions/workflows/${workflow_file}/dispatches" \
    2>/dev/null || echo "000")

  if [[ "$http_status" == "204" ]]; then
    _prl_info "Re-queued ${workflow_file} to resume deferred items (HTTP 204)"
  else
    _prl_warn "Dispatch of ${workflow_file} returned HTTP ${http_status} — items remain in var $(_prl_var_name)"
  fi
}

# ── Public API ────────────────────────────────────────────────────────────────

# pr_lifecycle_init WORKFLOW_FILE KEY
#   WORKFLOW_FILE — filename of the calling workflow (e.g. "ota-release.yml")
#   KEY           — short identifier used in the Actions variable name
#                   (e.g. "ota-deliver" → PR_LIFECYCLE_DEFER_OTA_DELIVER)
pr_lifecycle_init() {
  _PRL_WORKFLOW_FILE="${1:?pr_lifecycle_init: WORKFLOW_FILE required}"
  local raw_key="${2:?pr_lifecycle_init: KEY required}"
  # Sanitise: uppercase, replace non-alphanumeric with _, strip trailing _
  _PRL_KEY=$(echo "$raw_key" | tr '[:lower:]' '[:upper:]' | tr -cs 'A-Z0-9' '_' | sed 's/_$//')
  _PRL_PENDING=()
  _PRL_DONE=()
  _PRL_DEFERRED=false
  _prl_info "Initialised (workflow=${_PRL_WORKFLOW_FILE}, key=${_PRL_KEY}, min_quota=${_PRL_MIN_QUOTA})"
}

# pr_lifecycle_defer ITEM
#   Register an item as pending before processing it.
#   Call this at the top of the loop, before pr_lifecycle_check.
pr_lifecycle_defer() {
  local item="${1:?pr_lifecycle_defer: ITEM required}"
  _PRL_PENDING+=("$item")
}

# pr_lifecycle_check ITEM
#   Quota pre-flight. Returns 0 (proceed) or 1 (quota exhausted — caller should break).
#   On exhaustion: writes remaining pending items to the Actions variable,
#   dispatches the calling workflow, and sets _PRL_DEFERRED=true.
pr_lifecycle_check() {
  local item="${1:-item}"

  # Already deferred this run — keep returning 1 so the loop breaks cleanly
  [[ "$_PRL_DEFERRED" == "true" ]] && return 1

  local remaining
  remaining=$(_prl_quota_remaining)

  if [[ "$remaining" -lt "$_PRL_MIN_QUOTA" ]]; then
    _prl_warn "Quota exhausted (${remaining} < ${_PRL_MIN_QUOTA}) at item '${item}' — deferring remaining work"

    # Collect items not yet done: everything in _PRL_PENDING that isn't in _PRL_DONE
    local deferred=()
    for pending_item in "${_PRL_PENDING[@]}"; do
      local already_done=false
      for done_item in "${_PRL_DONE[@]}"; do
        [[ "$pending_item" == "$done_item" ]] && { already_done=true; break; }
      done
      [[ "$already_done" == "false" ]] && deferred+=("$pending_item")
    done

    if [[ "${#deferred[@]}" -gt 0 ]]; then
      local defer_value
      defer_value=$(printf '%s\n' "${deferred[@]}")
      _prl_set_var "$(_prl_var_name)" "$defer_value"
      _prl_info "Wrote ${#deferred[@]} deferred item(s) to $(_prl_var_name)"
      _prl_dispatch "$_PRL_WORKFLOW_FILE"
    fi

    _PRL_DEFERRED=true
    return 1
  fi

  return 0
}

# pr_lifecycle_done ITEM
#   Mark an item as successfully completed.
#   Call this after the PR work for an item succeeds.
pr_lifecycle_done() {
  local item="${1:?pr_lifecycle_done: ITEM required}"
  _PRL_DONE+=("$item")
}

# pr_lifecycle_report
#   Print a summary and clear the defer variable if all items completed.
#   Call once after the loop.
pr_lifecycle_report() {
  local total="${#_PRL_PENDING[@]}"
  local done="${#_PRL_DONE[@]}"
  local deferred=$(( total - done ))

  _prl_info "Report: ${done}/${total} items completed | deferred: ${deferred} | quota-deferred: ${_PRL_DEFERRED}"

  if [[ "$_PRL_DEFERRED" == "false" && "$deferred" -eq 0 ]]; then
    # All done — clear any leftover defer variable
    _prl_delete_var "$(_prl_var_name)"
    _prl_info "Cleared defer variable $(_prl_var_name)"
  fi
}

# pr_lifecycle_deferred
#   Returns 0 if a defer was triggered this run, 1 otherwise.
#   Useful for callers that want to set exit codes or output variables.
pr_lifecycle_deferred() {
  [[ "$_PRL_DEFERRED" == "true" ]]
}
