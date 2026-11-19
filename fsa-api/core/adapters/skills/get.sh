#!/usr/bin/env bash
# GET /api/fsa/skills/:name
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/fsa-adapter.sh"

name="${ROUTE_name:-}"
if [[ -z "$name" ]]; then
  fsa_error "Missing route param: name" 400
  exit 0
fi

exec python3 "${_FSA_ROOT}/scripts/agent-skills.py" get "$name"
