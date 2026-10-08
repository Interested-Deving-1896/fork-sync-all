#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../includes" && pwd)/platform-adapter.sh"
capacity_url_file=$(mktemp)
trap 'rm -f "$capacity_url_file"' EXIT

assert_json() {
  local payload="$1" expression="$2"
  python3 -c "import json,sys; data=json.load(sys.stdin); assert ${expression}" <<<"$payload"
}

reset_capacity_env() {
  unset PA_CAPACITY_LIMIT PA_CAPACITY_RUNNING PA_CAPACITY_QUEUED
  unset PA_CAPACITY_OLDEST_QUEUED_SECONDS PA_CAPACITY_STATUS_URL
  unset PA_CAPACITY_GITLAB_RUNNER_IDS
}

# Stable GitHub APIs do not report account-wide hosted-runner capacity. The
# adapter must preserve that uncertainty rather than assuming a plan limit.
reset_capacity_env
PA_PLATFORM="github"
PA_NAMESPACE="example-org"
observation=$(pa_query_capacity)
assert_json "$observation" \
  'data["platform"] == "github" and data["scope"] == "example-org"'
assert_json "$observation" \
  'data["total"] is None and data["limit"] is None and data["running"] is None and data["queued"] is None'
assert_json "$observation" \
  'data["available"] is None and data["confidence"] == "unknown" and data["source"] == "unknown"'
pa_capacity_supports configured-fallback
! pa_capacity_supports native-limit
! pa_capacity_supports native-running
! pa_capacity_supports native-queued

# Every forge can use an explicit fallback. Negative and non-numeric input is
# ignored, and availability never becomes negative at saturation.
reset_capacity_env
PA_PLATFORM="gitea"
PA_CAPACITY_LIMIT="20"
PA_CAPACITY_RUNNING="23"
PA_CAPACITY_QUEUED="4"
PA_CAPACITY_OLDEST_QUEUED_SECONDS="invalid"
observation=$(pa_capacity_query "gitea.example/team")
assert_json "$observation" \
  'data["limit"] == 20 and data["running"] == 23 and data["queued"] == 4'
assert_json "$observation" \
  'data["available"] == 0 and data["oldest_queued_seconds"] is None'
assert_json "$observation" \
  'data["confidence"] == "medium" and data["source"] == "configured"'

# A deployment-specific status endpoint is authenticated through pa_api_get.
# Explicit configuration wins, while missing fields are filled from the API.
reset_capacity_env
PA_PLATFORM="forgejo"
PA_CAPACITY_LIMIT="30"
PA_CAPACITY_STATUS_URL="https://forge.example/api/v1/admin/actions/capacity"
requested_url=""
pa_api_get() {
  requested_url="$1"
  printf '{"total":25,"active":7,"waiting":2,"oldest_age_seconds":91}\n'
  printf '%s\n' "$requested_url" >"$capacity_url_file"
}
observation=$(pa_query_capacity "forge.example/team")
[[ "$(cat "$capacity_url_file")" == "$PA_CAPACITY_STATUS_URL" ]]
assert_json "$observation" \
  'data["limit"] == 30 and data["running"] == 7 and data["queued"] == 2'
assert_json "$observation" \
  'data["available"] == 23 and data["oldest_age_seconds"] == 91 and data["oldest_queued_seconds"] == 91'
assert_json "$observation" \
  'data["confidence"] == "high" and data["source"] == "api+configured"'
capabilities=$(pa_capacity_capabilities)
assert_json "$capabilities" \
  'data["status_endpoint"] is True and data["runner_job_query"] is False'
assert_json "$capabilities" \
  'data["native_limit"] is False and data["native_running"] is False and data["native_queued"] is False'

# GitLab can count jobs for runner IDs that the caller is authorized to inspect.
# IDs are de-duplicated defensively, while the concurrency ceiling remains an
# explicit operator setting because the runners API does not expose it.
reset_capacity_env
PA_PLATFORM="gitlab"
PA_API="https://gitlab.example/api/v4"
PA_CAPACITY_LIMIT="8"
PA_CAPACITY_QUEUED="1"
PA_CAPACITY_GITLAB_RUNNER_IDS="11, 12"
pa_api_get() {
  case "$1" in
    *'/runners/11/jobs?'*) printf '[{"id":101},{"id":102}]\n' ;;
    *'/runners/12/jobs?'*) printf '[{"id":102},{"id":103}]\n' ;;
    *) return 1 ;;
  esac
}
observation=$(pa_query_capacity "group/subgroup")
assert_json "$observation" \
  'data["limit"] == 8 and data["running"] == 3 and data["queued"] == 1'
assert_json "$observation" \
  'data["available"] == 5 and data["confidence"] == "high"'
assert_json "$observation" \
  'data["source"] == "configured+runner-api"'
capabilities=$(pa_capacity_capabilities)
assert_json "$capabilities" \
  'data["status_endpoint"] is False and data["runner_job_query"] is True'

# Malformed optional API data must preserve a valid configured fallback.
reset_capacity_env
PA_PLATFORM="codeberg"
PA_CAPACITY_LIMIT="10"
PA_CAPACITY_STATUS_URL="https://codeberg.example/capacity"
pa_api_get() { printf 'not-json\n'; }
observation=$(pa_query_capacity "codeberg.org/example")
assert_json "$observation" \
  'data["limit"] == 10 and data["running"] is None and data["source"] == "configured"'
assert_json "$observation" 'data["confidence"] == "low"'

echo "platform-adapter capacity discovery: ok"
