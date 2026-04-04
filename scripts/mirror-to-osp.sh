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

synced=0
failed=0
skipped=0

# ── helpers ────────────────────────────────────────────────────────────────

is_excluded() {
  local repo="$1"
  for excluded in "${EXCLUDED_REPOS[@]}"; do
    [[ "$repo" == "$excluded" ]] && return 0
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

get_osp_repos() {
  local page=1
  while true; do
    local result count
    result=$(api_get "${API}/orgs/${OSP_ORG}/repos?type=all&per_page=${PER_PAGE}&page=${page}")
    count=$(echo "$result" | jq 'length' 2>/dev/null) || break
    [[ -z "$count" || "$count" == "0" || "$count" == "null" ]] && break
    echo "$result" | jq -r '.[].name' 2>/dev/null
    (( page++ ))
  done
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

  local attempt=0 push_ok=false push_output sanitized
  while (( attempt < 3 )); do
    push_output=$(git push --mirror "$target_url" 2>&1) || true
    sanitized=$(echo "$push_output" | sanitize)

    if ! echo "$push_output" | grep -q "remote rejected"; then
      echo "$sanitized"
      push_ok=true
      break
    fi

    # workflow scope error — retrying won't help
    if echo "$push_output" | grep -q "without \`workflow\` scope"; then
      echo "$sanitized"
      echo "  ERROR: GH_TOKEN needs the 'workflow' scope to push repos containing .github/workflows/"
      break
    fi

    (( attempt++ ))
    echo "$sanitized"
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
if ! api_get "${API}/user" | jq -e '.login' >/dev/null 2>&1; then
  echo "ERROR: GH_TOKEN is invalid or lacks required permissions."
  exit 1
fi
echo "Token OK."
echo ""

echo "Fetching repos from ${OSP_ORG}..."
mapfile -t osp_repos < <(get_osp_repos)
echo "Found ${#osp_repos[@]} repos in ${OSP_ORG}."
echo ""

for name in "${osp_repos[@]}"; do
  [[ -z "$name" ]] && continue

  if is_excluded "$name"; then
    (( skipped++ )) || true
    continue
  fi

  # Check if this repo exists on the upstream — if not, it's OSP-native, skip it
  upstream_info=$(api_get "${API}/repos/${UPSTREAM_OWNER}/${name}" 2>/dev/null)
  upstream_exists=$(echo "$upstream_info" | jq -r '.name // empty' 2>/dev/null)

  if [[ -z "$upstream_exists" ]]; then
    (( skipped++ )) || true
    continue
  fi

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
echo "  Repos failed:  ${failed}"
echo "========================================================"

if [[ "$synced" -eq 0 && "$failed" -gt 0 ]]; then
  echo ""
  echo "All repos failed. Check GH_TOKEN permissions (needs: repo, admin:org, workflow)."
  exit 1
fi

exit 0
