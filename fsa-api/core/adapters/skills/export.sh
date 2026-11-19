#!/usr/bin/env bash
# POST /api/fsa/skills/export
# Body: {"name":"example","provider":"claude","dry_run":true,"replace":false}
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/fsa-adapter.sh"

name="${BODY_name:-}"
provider="${BODY_provider:-}"
dry_run="${BODY_dry_run:-true}"
replace="${BODY_replace:-false}"

if [[ -z "$name" || -z "$provider" ]]; then
  fsa_error "Missing required fields: name and provider" 400
  exit 0
fi
if [[ "$dry_run" != "true" && "$dry_run" != "false" ]]; then
  fsa_error "dry_run must be true or false" 400
  exit 0
fi
if [[ "$replace" != "true" && "$replace" != "false" ]]; then
  fsa_error "replace must be true or false" 400
  exit 0
fi

args=(export "$name" "$provider")
[[ "$dry_run" == "false" ]] && args+=(--materialize)
[[ "$replace" == "true" ]] && args+=(--replace)
exec python3 "${_FSA_ROOT}/scripts/agent-skills.py" "${args[@]}"
