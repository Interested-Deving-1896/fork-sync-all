#!/usr/bin/env bash
# GET /api/fsa/governance/agent-evidence/:pr
# Read-only, report-only assessment of the newest marked evidence comment.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/fsa-adapter.sh"

PR_NUMBER="${ROUTE_pr:-}"
if [[ ! "${PR_NUMBER}" =~ ^[1-9][0-9]*$ ]]; then
  fsa_error "pull request number must be a positive integer" 400
  exit 0
fi

REPO_FULL="${FSA_REPO}"
if [[ "${REPO_FULL}" != */* ]]; then
  REPO_FULL="${FSA_ORG}/${FSA_REPO}"
fi

PR_JSON="$(fsa_api_get "/repos/${REPO_FULL}/pulls/${PR_NUMBER}")"
HEAD_SHA="$(printf '%s' "${PR_JSON}" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("head") or {}).get("sha", ""))' 2>/dev/null || true)"
if [[ ! "${HEAD_SHA}" =~ ^[0-9a-f]{40}$ ]]; then
  fsa_error "unable to resolve pull request head SHA" 404
  exit 0
fi

if [[ -n "${QUERY_head_sha:-}" && "${QUERY_head_sha}" != "${HEAD_SHA}" ]]; then
  fsa_error "requested head SHA does not match current pull request head" 409
  exit 0
fi

export GITHUB_REPOSITORY="${REPO_FULL}"
export GITHUB_TOKEN="${GH_TOKEN}"
export GITHUB_API_URL="${GH_API}"
export PR_NUMBER
export PR_HEAD_SHA="${HEAD_SHA}"

exec python3 "${_FSA_ROOT}/scripts/report-agent-evidence-pr.py"
