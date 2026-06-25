#!/usr/bin/env bash
# POST /api/fsa/workflows/:name/run
# Dispatches a workflow_dispatch event for the named workflow.
#
# Path param:  :name  — workflow filename (e.g. sync-forks.yml) or display name
# Body (JSON): { "inputs": { "key": "value" }, "ref": "main" }
#
# Returns: { "ok": true, "run_url": "...", "workflow": "..." }
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/fsa-adapter.sh"

WORKFLOW_NAME="${PATH_name:-}"
REF="${BODY_ref:-main}"

if [[ -z "$WORKFLOW_NAME" ]]; then
  fsa_error "workflow name is required" 400
  exit 0
fi

# Resolve filename if display name was given
resolve_workflow_file() {
  local name="$1"
  local workflows_dir="${_FSA_ROOT}/.github/workflows"
  # Exact filename match
  [[ -f "${workflows_dir}/${name}" ]] && echo "$name" && return
  [[ -f "${workflows_dir}/${name}.yml" ]] && echo "${name}.yml" && return
  # Match by display name
  for f in "${workflows_dir}"/*.yml "${workflows_dir}"/*.yaml; do
    [[ -f "$f" ]] || continue
    wname=$(python3 -c "import yaml; d=yaml.safe_load(open('$f')); print(d.get('name',''))" 2>/dev/null || echo "")
    if [[ "$wname" == "$name" ]]; then
      echo "$(basename "$f")"
      return
    fi
  done
  echo ""
}

workflow_file=$(resolve_workflow_file "$WORKFLOW_NAME")
if [[ -z "$workflow_file" ]]; then
  fsa_error "workflow not found: ${WORKFLOW_NAME}" 404
  exit 0
fi

# Check toggle
toggle_key="${workflow_file}"
if ! fsa_toggle_enabled "$toggle_key" 2>/dev/null; then
  fsa_error "workflow is disabled by toggle: ${workflow_file}" 403
  exit 0
fi

fsa_quota_check 50 || exit 0

# Parse inputs from request body
inputs_json="${BODY_inputs:-{}}"

# Dispatch
result=$(fsa_api_post \
  "/repos/${FSA_REPO}/actions/workflows/${workflow_file}/dispatches" \
  "{\"ref\":\"${REF}\",\"inputs\":${inputs_json}}")

# GitHub returns 204 No Content on success — empty body = success
if [[ -z "$result" ]] || echo "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if not d.get('message') else 1)" 2>/dev/null; then
  # Get the run URL (latest run for this workflow)
  sleep 2
  runs=$(fsa_api_get "/repos/${FSA_REPO}/actions/workflows/${workflow_file}/runs?per_page=1")
  run_url=$(echo "$runs" | python3 -c "
import json,sys
d=json.load(sys.stdin)
runs=d.get('workflow_runs',[])
print(runs[0].get('html_url','') if runs else '')
" 2>/dev/null || echo "")
  echo "{\"ok\":true,\"workflow\":\"${workflow_file}\",\"ref\":\"${REF}\",\"run_url\":\"${run_url}\"}"
else
  msg=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('message','dispatch failed'))" 2>/dev/null || echo "dispatch failed")
  fsa_error "$msg" 422
fi
