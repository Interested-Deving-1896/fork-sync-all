#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# The lifecycle adapter is intentionally sourced without real credentials.
source "${repo_root}/fsa-api/core/lib/fsa-adapter.sh"

# An initialized provider whose quota probe cannot produce a value must fail
# closed rather than advertising the old fabricated 9999-call allowance.
PA_PLATFORM="github"
pa_rate_limit_remaining() { return 1; }
[[ "$(quota_fetch)" == "0" ]]

# A valid observation is passed through unchanged.
pa_rate_limit_remaining() { printf '37\n'; }
[[ "$(quota_fetch)" == "37" ]]

echo "FSA adapter quota fail-closed behavior: ok"
