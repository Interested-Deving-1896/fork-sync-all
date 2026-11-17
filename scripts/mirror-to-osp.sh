#!/usr/bin/env bash
#
# Source → OSP mirror inspection. The historical push implementation below
# is retained temporarily for reference, but live execution is hard-disabled
# until a non-destructive branch/tag planner and staged admission gates land.
set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${UPSTREAM_OWNER:?UPSTREAM_OWNER is required}"
: "${OSP_ORG:?OSP_ORG is required}"

DRY_RUN="${DRY_RUN:-true}"
REPO_FILTER="${REPO_FILTER:-}"
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_SCRIPT_DIR}/includes/budget.sh"
FORCE="${FORCE:-false}"

if [[ "$DRY_RUN" != "true" ]]; then
  echo "ERROR: live source-to-OSP mirroring is disabled pending the safe ref planner." >&2
  exit 2
fi

echo "Dry run — source-to-OSP writes are disabled."
[[ -n "$REPO_FILTER" ]] && echo "Repo filter: '${REPO_FILTER}'"

API="https://api.github.com"
AUTH_HEADER="Authorization: token ${GH_TOKEN}"
ACCEPT_HEADER="Accept: application/vnd.github+json"
EXCLUDED_REPOS=("fork-sync-all" "org-mirror" "talos-incus")
NO_GATE_REPOS=("talos")
synced=0
failed=0
skipped=0
gated=0

api_get() {
  curl --disable --silent -H "$AUTH_HEADER" -H "$ACCEPT_HEADER" "$@"
}

fetch_repo_metadata() {
  local osp="$1"
  curl -sf \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Content-Type: application/json" \
    "${API}/graphql" \
    -d "{\"query\":\"{ organization(login: \\\"${osp}\\\") { repositories(first: 100) { nodes { name } } } }\"}" \
    | jq -r '.data.organization.repositories.nodes[].name' 2>/dev/null
}

fetch_upstream_ci_data() {
  local repos=("$@") aliases="" i=0
  for name in "${repos[@]}"; do
    aliases+="r${i}: repository(owner: \\\"${UPSTREAM_OWNER}\\\", name: \\\"${name}\\\") { name defaultBranchRef { target { oid } } pullRequests(states: OPEN, baseRefName: \\\"main\\\", first: 1) { totalCount } } "
    (( i++ )) || true
  done
  curl -sf \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Content-Type: application/json" \
    "${API}/graphql" \
    -d "{\"query\":\"{ ${aliases} }\"}" 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin).get('data', {})
out = {}
for val in data.values():
    if not val: continue
    ref = val.get('defaultBranchRef')
    out[val.get('name', '')] = {
        'sha': ref.get('target', {}).get('oid', '') if ref else '',
        'prs': val.get('pullRequests', {}).get('totalCount', 0),
    }
print(json.dumps(out))
" 2>/dev/null || echo "{}"
}

echo "Validating token..."
_user=$(curl -sf -H "Authorization: token ${GH_TOKEN}" "${API}/user" | jq -r '.login // empty' 2>/dev/null)
if [[ -z "$_user" ]]; then
  echo "ERROR: GH_TOKEN is invalid or lacks required permissions." >&2
  exit 1
fi
echo "Token OK (${_user})."
mapfile -t osp_repos < <(fetch_repo_metadata "$OSP_ORG")
echo "Found ${#osp_repos[@]} OSP repositories."
_upstream_data=$(fetch_upstream_ci_data "${osp_repos[@]}")
budget_init

for name in "${osp_repos[@]}"; do
  [[ -z "$name" ]] && continue
  budget_check "$name" || break
  if [[ " ${EXCLUDED_REPOS[*]} " == *" $name "* ]]; then
    (( skipped++ )) || true
    continue
  fi
  if [[ -n "$REPO_FILTER" && "$name" != *"$REPO_FILTER"* ]]; then
    (( skipped++ )) || true
    continue
  fi
  exists=$(echo "$_upstream_data" | python3 -c "
import json, sys
print('yes' if '${name}' in json.load(sys.stdin) else '')
" 2>/dev/null || echo "")
  if [[ -z "$exists" ]]; then (( skipped++ )) || true; continue; fi
  echo "DRY  would mirror ${UPSTREAM_OWNER}/${name} → ${OSP_ORG}/${name}"
  (( synced++ )) || true
done

echo "Inspection complete: ${synced} eligible, ${skipped} skipped, ${failed} failed."
budget_report
exit 0
