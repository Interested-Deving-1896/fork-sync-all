#!/usr/bin/env bash
# Shared safety policy for commands that mutate the authenticated user's
# GitHub notification inbox.

if [[ -n "${_NOTIFICATION_POLICY_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_NOTIFICATION_POLICY_LOADED=1

# Return success only when a repository is inside the resolver's declared
# owner/repository scope. GitHub's notifications API is user-global, so callers
# must apply this check before acting on a thread.
notification_repo_in_scope() {
  local repo_full="$1"
  local owner="${repo_full%%/*}"
  local repo="${repo_full#*/}"
  local configured_owner
  local owner_allowed=false

  [[ -n "$repo_full" && "$owner" != "$repo_full" && -n "$repo" ]] || return 1

  for configured_owner in ${SCAN_OWNERS:-}; do
    if [[ "$owner" == "$configured_owner" ]]; then
      owner_allowed=true
      break
    fi
  done
  [[ "$owner_allowed" == "true" ]] || return 1

  if [[ -n "${REPO_FILTER:-}" && "$repo" != *"${REPO_FILTER}"* ]]; then
    return 1
  fi

  # The canonical source owner is intentionally narrowed to its OSP-bound
  # repositories when the workflow supplies OSP_REPOS_OVERRIDE.
  if [[ "$owner" == "Interested-Deving-1896" && -n "${OSP_REPOS_OVERRIDE:-}" ]]; then
    local configured_repo
    for configured_repo in $OSP_REPOS_OVERRIDE; do
      [[ "$repo" == "$configured_repo" ]] && return 0
    done
    return 1
  fi

  return 0
}

notification_is_ci_candidate() {
  local reason="$1"
  local subject_type="$2"
  [[ "$reason" == "ci_activity" && "$subject_type" == "CheckSuite" ]]
}
