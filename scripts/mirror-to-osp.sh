#!/usr/bin/env bash
#
# For every repo present on both UPSTREAM_OWNER and OSP_ORG, does a
# bare clone of the upstream and git push --mirror into OSP, syncing
# all branches, tags, and refs exactly.
#
# Repos that exist only in OSP (org-native, not mirrored) are skipped
# automatically — they won't be found on UPSTREAM_OWNER.
#
# Requires: GH_TOKEN (repo + admin:org + workflow scopes, write access
#           to OSP_ORG and read access to UPSTREAM_OWNER),
#           UPSTREAM_OWNER, OSP_ORG
#
set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${UPSTREAM_OWNER:?UPSTREAM_OWNER is required}"
: "${OSP_ORG:?OSP_ORG is required}"

# Optional filters / flags (from workflow_dispatch inputs)
DRY_RUN="${DRY_RUN:-false}"
REPO_FILTER="${REPO_FILTER:-}"

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/includes/budget.sh
source "${_SCRIPT_DIR}/includes/budget.sh"
FORCE="${FORCE:-false}"

[[ "$DRY_RUN" == "true" ]] && echo "Dry run — no pushes will occur."
[[ "$FORCE"   == "true" ]] && echo "Force mode — CI gate bypassed for all repos."
[[ -n "$REPO_FILTER"    ]] && echo "Repo filter: '${REPO_FILTER}'"

API="https://api.github.com"
AUTH_HEADER="Authorization: token ${GH_TOKEN}"
ACCEPT_HEADER="Accept: application/vnd.github+json"
PER_PAGE=100

# Repos with custom setups that must never be touched
EXCLUDED_REPOS=(
  "fork-sync-all"
  "org-mirror"
  "talos-incus"
)

# Repos that bypass the CI gate — their CI requires private infrastructure
# (e.g. private BuildKit clusters, Slack webhooks) that will never pass in
# the GitHub Actions environment. They are still mirrored; only the gate is skipped.
NO_GATE_REPOS=(
  "talos"
)

synced=0
failed=0
skipped=0
gated=0

# ── helpers ────────────────────────────────────────────────────────────────

is_excluded() {
  local repo="$1"
  for excluded in "${EXCLUDED_REPOS[@]}"; do
    [[ "$repo" == "$excluded" ]] && return 0
  done
  return 1
}

is_no_gate() {
  local repo="$1"
  for ng in "${NO_GATE_REPOS[@]}"; do
    [[ "$repo" == "$ng" ]] && return 0
  done
  return 1
}

api_get() {
  curl --disable --silent \
    -H "$AUTH_HEADER" \
    -H "$ACCEPT_HEADER" \
    "$@"
}

sanitize() {
  sed "s/${GH_TOKEN}/***TOKEN***/g"
}

# Fetch all repo names + upstream existence + CI status in one GraphQL call.
# Returns a JSON object keyed by repo name with fields:
#   exists_upstream, default_sha, failing_checks, open_prs
fetch_repo_metadata() {
  local owner="$1"   # upstream owner (Interested-Deving-1896)
  local osp="$2"     # OSP org

  # First get OSP repo list via GraphQL (1 call regardless of repo count)
  local osp_names
  osp_names=$(curl -sf \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Content-Type: application/json" \
    "${API}/graphql" \
    -d "{\"query\":\"{ organization(login: \\\"${osp}\\\") { repositories(first: 100) { nodes { name } } } }\"}" \
    | jq -r '.data.organization.repositories.nodes[].name' 2>/dev/null)

  echo "$osp_names"
}

get_osp_repos() {
  fetch_repo_metadata "$UPSTREAM_OWNER" "$OSP_ORG"
}

# Fetch upstream existence + CI data for all repos in one GraphQL call.
# Outputs JSON: {"reponame": {"exists": true, "sha": "abc", "failing": 0, "prs": 0}, ...}
fetch_upstream_ci_data() {
  local repos=("$@")
  local aliases="" i=0

  for name in "${repos[@]}"; do
    local safe
    safe=$(echo "$name" | tr '-' '_' | tr '.' '_')
    aliases+="r${i}: repository(owner: \\\"${UPSTREAM_OWNER}\\\", name: \\\"${name}\\\") {
      name
      defaultBranchRef { target { oid } }
      pullRequests(states: OPEN, baseRefName: \\\"main\\\", first: 1) { totalCount }
    } "
    (( i++ )) || true
  done

  local query="{${aliases}}"
  local result
  result=$(curl -sf \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Content-Type: application/json" \
    "${API}/graphql" \
    -d "{\"query\":\"{ ${aliases} }\"}" 2>/dev/null || echo "{}")

  # Convert to simple lookup: name -> {sha, prs}
  echo "$result" | python3 -c "
import json, sys
data = json.load(sys.stdin).get('data', {})
out = {}
for key, val in data.items():
    if not val:
        continue
    name = val.get('name', '')
    sha = ''
    ref = val.get('defaultBranchRef')
    if ref and ref.get('target'):
        sha = ref['target'].get('oid', '')
    prs = val.get('pullRequests', {}).get('totalCount', 0)
    out[name] = {'sha': sha, 'prs': prs}
print(json.dumps(out))
" 2>/dev/null || echo "{}"
}

mirror_repo() {
  local name="$1"
  local tmpdir clonedir
  tmpdir=$(mktemp -d)
  clonedir="${tmpdir}/${name}.git"

  local upstream_url target_url
  upstream_url="https://x-access-token:${GH_TOKEN}@github.com/${UPSTREAM_OWNER}/${name}.git"
  target_url="https://x-access-token:${GH_TOKEN}@github.com/${OSP_ORG}/${name}.git"

  # Bare clone from upstream
  if ! git clone --bare "$upstream_url" "$clonedir" 2>&1 | sanitize; then
    echo "  failed: could not clone ${UPSTREAM_OWNER}/${name}"
    rm -rf "$tmpdir"
    return 1
  fi

  cd "$clonedir" || return 1

  local attempt=0 push_ok=false push_output push_exit sanitized
  while (( attempt < 3 )); do
    push_output=$(git push --mirror "$target_url" 2>&1)
    push_exit=$?
    sanitized=$(echo "$push_output" | sanitize)
    echo "$sanitized"

    if [[ "$push_exit" -eq 0 ]]; then
      # git push itself succeeded — done
      push_ok=true
      break
    fi

    # git push failed — inspect why before deciding whether to retry
    if echo "$push_output" | grep -q "without \`workflow\` scope"; then
      echo "  ERROR: GH_TOKEN needs the 'workflow' scope to push repos containing .github/workflows/"
      break  # retrying won't help
    fi

    if echo "$push_output" | grep -q "remote rejected"; then
      # Remote rejection (e.g. protected branch) — retrying won't help
      echo "  ERROR: push rejected by remote"
      break
    fi

    # Transient error (network, auth timeout, etc.) — retry with back-off
    (( attempt++ ))
    if (( attempt < 3 )); then
      echo "  push attempt ${attempt} failed, retrying in 5s..."
      sleep 5
    fi
  done

  cd /
  rm -rf "$tmpdir"

  if $push_ok; then return 0; fi
  echo "  failed: could not push to ${OSP_ORG}/${name}"
  return 1
}

# ── main ───────────────────────────────────────────────────────────────────

echo "Validating token..."
_user=$(curl -sf -H "Authorization: token ${GH_TOKEN}" "${API}/user" | jq -r '.login // empty' 2>/dev/null)
if [[ -z "$_user" ]]; then
  echo "ERROR: GH_TOKEN is invalid or lacks required permissions."
  exit 1
fi
echo "Token OK (${_user})."
echo ""

echo "Fetching repos from ${OSP_ORG} via GraphQL..."
mapfile -t osp_repos < <(get_osp_repos)
echo "Found ${#osp_repos[@]} repos in ${OSP_ORG}."
echo ""

# Pre-fetch upstream existence + CI data for all repos in one GraphQL call.
# This replaces O(repos) REST calls with a single GraphQL request.
echo "Pre-fetching upstream metadata via GraphQL (1 call for all repos)..."
_upstream_data=$(fetch_upstream_ci_data "${osp_repos[@]}")
echo "Upstream metadata fetched."
echo ""

budget_init

for name in "${osp_repos[@]}"; do
  [[ -z "$name" ]] && continue
  budget_check "$name" || break

  if is_excluded "$name"; then
    (( skipped++ )) || true
    continue
  fi

  # Apply repo name substring filter
  if [[ -n "$REPO_FILTER" && "$name" != *"$REPO_FILTER"* ]]; then
    (( skipped++ )) || true
    continue
  fi

  # Check upstream existence from pre-fetched data (no REST call)
  upstream_exists=$(echo "$_upstream_data" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print('yes' if '${name}' in data else '')
" 2>/dev/null || echo "")

  if [[ -z "$upstream_exists" ]]; then
    (( skipped++ )) || true
    continue
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "DRY  would mirror ${UPSTREAM_OWNER}/${name} → ${OSP_ORG}/${name}"
    (( synced++ )) || true
    continue
  fi

  # ── CI gate ────────────────────────────────────────────────────────────────
  # Uses pre-fetched GraphQL data — no per-repo REST calls.
  # Failing check-runs still require a REST call (GraphQL doesn't expose them
  # cleanly), but only for repos that pass the PR gate first.
  if [[ "$FORCE" == "true" ]] || is_no_gate "$name"; then
    echo "Mirroring ${UPSTREAM_OWNER}/${name} → ${OSP_ORG}/${name} (gate bypassed)..."
    if mirror_repo "$name"; then
      (( synced++ )) || true
      echo "  done."
    else
      (( failed++ )) || true
    fi
    continue
  fi

  # PR gate — from pre-fetched data (no REST call)
  open_prs=$(echo "$_upstream_data" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('${name}', {}).get('prs', 0))
" 2>/dev/null || echo 0)

  if [[ "$open_prs" -gt 0 ]]; then
    echo "  GATE: ${name} has ${open_prs} open PR(s) targeting main — will retry next run"
    (( gated++ )) || true
    continue
  fi

  # Check-runs gate — still needs REST (GraphQL check-runs API is limited)
  # Only called for repos that passed the PR gate above.
  main_sha=$(echo "$_upstream_data" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('${name}', {}).get('sha', ''))
" 2>/dev/null || echo "")

  if [[ -n "$main_sha" ]]; then
    failing_checks=$(api_get "${API}/repos/${UPSTREAM_OWNER}/${name}/commits/${main_sha}/check-runs?per_page=100" \
      | jq -r '[.check_runs[]
          | select(.conclusion == "failure" or .conclusion == "timed_out")
          | select(.name | test("^mirror|^Mirror|setup-osp-mirrors|mirror-osp-to-ooc|^Build CI image:|^slack-notify"; "i") | not)
        ] | length' \
      2>/dev/null || echo 0)

    if [[ "$failing_checks" -gt 0 ]]; then
      echo "  GATE: ${name} has ${failing_checks} failing CI check(s) on main — will retry next run"
      (( gated++ )) || true
      continue
    fi
  fi
  # ── end CI gate ────────────────────────────────────────────────────────────

  echo "Mirroring ${UPSTREAM_OWNER}/${name} → ${OSP_ORG}/${name}..."

  if mirror_repo "$name"; then
    (( synced++ )) || true
    echo "  done."
  else
    (( failed++ )) || true
  fi
done

echo ""
echo "========================================================"
echo "  Mirror complete: ${UPSTREAM_OWNER} → ${OSP_ORG}"
echo "  Repos synced:  ${synced}"
echo "  Repos skipped: ${skipped}"
echo "  Repos gated:   ${gated}  (failing CI or open PRs on main)"
echo "  Repos failed:  ${failed}"
echo "========================================================"

if [[ "$synced" -eq 0 && "$failed" -gt 0 ]]; then
  echo ""
  echo "All repos failed. Check GH_TOKEN permissions (needs: repo, admin:org, workflow)."
  exit 1
fi

budget_report
exit 0
