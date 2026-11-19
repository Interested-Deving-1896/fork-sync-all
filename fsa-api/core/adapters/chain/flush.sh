#!/usr/bin/env bash
# POST /api/fsa/chain/flush
# Triggers a full chain flush via full-chain-flush.yml workflow_dispatch.
#
# Body (JSON): { "aggressive": false, "ref": "main" }
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/fsa-adapter.sh"

REF="${BODY_ref:-main}"
AGGRESSIVE="${BODY_aggressive:-false}"

fsa_quota_check 100 || exit 0

result=$(fsa_api_post \
  "/repos/${FSA_REPO}/actions/workflows/full-chain-flush.yml/dispatches" \
  "{\"ref\":\"${REF}\",\"inputs\":{\"aggressive_clear\":\"${AGGRESSIVE}\"}}")

if [[ -z "$result" ]] || echo "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if not d.get('message') else 1)" 2>/dev/null; then
  echo "{\"ok\":true,\"message\":\"Full chain flush dispatched\",\"ref\":\"${REF}\",\"aggressive\":${AGGRESSIVE}}"
else
  msg=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('message','dispatch failed'))" 2>/dev/null || echo "dispatch failed")
  fsa_error "$msg" 422
fi
