#!/usr/bin/env bash
# POST /api/fsa/skills/validate
# Body: {"path":".agents/skills/example"}
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/fsa-adapter.sh"

path="${BODY_path:-}"
if [[ -z "$path" ]]; then
  fsa_error "Missing required field: path" 400
  exit 0
fi

exec python3 "${_FSA_ROOT}/scripts/agent-skills.py" validate "$path"
