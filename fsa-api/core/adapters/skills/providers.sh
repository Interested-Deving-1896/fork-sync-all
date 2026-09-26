#!/usr/bin/env bash
# GET /api/fsa/skills/providers
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/fsa-adapter.sh"

exec python3 "${_FSA_ROOT}/scripts/agent-skills.py" providers
