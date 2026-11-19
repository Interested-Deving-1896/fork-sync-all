#!/usr/bin/env bash
# Cooperative admission/checkpoint helpers for AI coding-agent work.
#
# Callers need GH_TOKEN and GITHUB_REPOSITORY (or AGENT_BUDGET_REPOSITORY).
# Return codes: 0 = admitted, 3 = defer/checkpoint, other = configuration error.

if [[ -n "${_AGENT_BUDGET_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_AGENT_BUDGET_LOADED=1

_agent_budget_include_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${_agent_budget_include_dir}/gh-api.sh"

_agent_budget_log() { echo "[agent-budget] $*" >&2; }

_agent_budget_suffix() {
  printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_'
}

agent_budget_load_state() {
  local provider="${1:?provider is required}"
  local destination="${2:?destination path is required}"
  local repository="${AGENT_BUDGET_REPOSITORY:-${GITHUB_REPOSITORY:-}}"
  local suffix variable
  [[ -n "$repository" ]] || { _agent_budget_log "GITHUB_REPOSITORY is required"; return 1; }
  [[ -n "${GH_TOKEN:-}" ]] || { _agent_budget_log "GH_TOKEN is required"; return 1; }

  suffix=$(_agent_budget_suffix "$provider")
  variable="AI_AGENT_BUDGET_STATE_${suffix}"
  local response
  if response=$(gh_get "https://api.github.com/repos/${repository}/actions/variables/${variable}"); then
    if ! python3 -c 'import json,sys; print(json.load(sys.stdin).get("value", ""))' \
      <<< "$response" > "$destination"; then
      _agent_budget_log "Invalid state response for provider '${provider}'"
      : > "$destination"
    fi
  else
    _agent_budget_log "No observation is available for provider '${provider}'"
    : > "$destination"
  fi
}

agent_budget_admit() {
  local provider="${1:?provider is required}"
  local task="${2:-}"
  local required_units="${3:-}"
  local state_file
  state_file=$(mktemp "${TMPDIR:-/tmp}/agent-budget.XXXXXX.json")
  agent_budget_load_state "$provider" "$state_file" || {
    rm -f "$state_file"
    return 1
  }

  local args=(python3 scripts/agent-budget-governor.py
    --config "${AGENT_BUDGET_CONFIG:-config/agent-budget.yml}"
    --provider "$provider"
    --state "$state_file"
    check)
  [[ -n "$task" ]] && args+=(--task "$task")
  [[ -n "$required_units" ]] && args+=(--required-units "$required_units")

  local rc
  if "${args[@]}"; then
    rc=0
  else
    rc=$?
  fi
  rm -f "$state_file"
  if [[ $rc -eq 3 ]]; then
    _agent_budget_log "Work deferred for provider '${provider}'"
  fi
  return "$rc"
}

agent_budget_checkpoint() {
  agent_budget_admit "$@"
}
