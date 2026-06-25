#!/usr/bin/env bash
# POST /api/fsa/repos/onboard
# Triggers the Onboard Repo workflow for a given repo name.
#
# Body (JSON): { "repo": "repo-name", "dry_run": false }
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/fsa-adapter.sh"

REPO_NAME="${BODY_repo:-}"
DRY_RUN="${BODY_dry_run:-false}"

if [[ -z "$REPO_NAME" ]]; then
  fsa_error "Missing required field: repo" 400
  exit 0
fi

fsa_quota_check 20 || exit 0

if [[ "$DRY_RUN" == "true" ]]; then
  echo "{\"ok\":true,\"dry_run\":true,\"repo\":\"${REPO_NAME}\",\"message\":\"Would trigger Onboard Repo workflow\"}"
  exit 0
fi

result=$(fsa_api POST "/repos/${FSA_ORG}/${FSA_REPO}/actions/workflows/onboard-repo.yml/dispatches" \
  "{\"ref\":\"main\",\"inputs\":{\"repo\":\"${REPO_NAME}\"}}")

if echo "$result" | grep -q '"message"'; then
  err=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('message','unknown error'))" 2>/dev/null)
  fsa_error "Workflow dispatch failed: $err" 502
else
  echo "{\"ok\":true,\"repo\":\"${REPO_NAME}\",\"message\":\"Onboard Repo workflow dispatched\"}"
fi
