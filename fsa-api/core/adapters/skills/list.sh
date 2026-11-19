#!/usr/bin/env bash
# GET /api/fsa/skills
# Query: ?provider=all|<configured-provider>
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/fsa-adapter.sh"

exec python3 "${_FSA_ROOT}/scripts/agent-skills.py" list \
  --provider "${QUERY_provider:-all}"
