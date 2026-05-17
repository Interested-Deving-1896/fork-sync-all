#!/usr/bin/env bash
#
# Syncs branches from kdave/btrfs-devel into
# Interested-Deving-1896/linux-merge via the GitHub API (no git clone).
#
# Because GitHub allows only one fork per root repository, btrfs-devel cannot
# be forked directly into I-D-1896 — both repos share the linux kernel object
# store, so SHAs are reachable across the fork network via the API.
#
# For each branch in kdave/btrfs-devel:
#   - If the branch exists in linux-merge: PATCH /git/refs/heads/<branch>
#   - If it does not exist:               POST  /git/refs
#
# Required env vars:
#   GH_TOKEN  — PAT with repo scope on Interested-Deving-1896
#
# Optional env vars:
#   BRANCHES   — space-separated list of branches to sync (default: all)
#   DRY_RUN    — if "true", print actions without making API calls
#   SOURCE_REPO  — upstream repo (default: kdave/btrfs-devel)
#   TARGET_REPO  — destination repo (default: Interested-Deving-1896/linux-merge)

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"

API="https://api.github.com"
AUTH=(-H "Authorization: token ${GH_TOKEN}" -H "Accept: application/vnd.github+json")

SOURCE_REPO="${SOURCE_REPO:-kdave/btrfs-devel}"
TARGET_REPO="${TARGET_REPO:-Interested-Deving-1896/linux-merge}"
DRY_RUN="${DRY_RUN:-false}"
BRANCHES="${BRANCHES:-}"   # blank = all branches

api_get() {
  curl --disable --silent --fail "${AUTH[@]}" "$@"
}

api_post() {
  curl --disable --silent --fail -X POST "${AUTH[@]}" -H "Content-Type: application/json" "$@"
}

api_patch() {
  curl --disable --silent --fail -X PATCH "${AUTH[@]}" -H "Content-Type: application/json" "$@"
}

# List all branches in SOURCE_REPO
list_source_branches() {
  local page=1
  while true; do
    local result count
    result=$(api_get "${API}/repos/${SOURCE_REPO}/branches?per_page=100&page=${page}")
    count=$(echo "$result" | jq 'length' 2>/dev/null || echo 0)
    [[ "$count" == "0" || "$count" == "null" ]] && break
    echo "$result" | jq -r '.[].name'
    (( page++ ))
  done
}

# Get SHA of a branch in a repo; returns empty string if not found.
# curl --fail exits 22 on 404; suppress that so set -e doesn't abort the caller.
get_branch_sha() {
  local repo="$1" branch="$2"
  api_get "${API}/repos/${repo}/git/ref/heads/${branch}" 2>/dev/null \
    | jq -r '.object.sha // empty' || true
}

synced=0
skipped=0
failed=0

echo "Syncing branches: ${SOURCE_REPO} → ${TARGET_REPO}"
[[ "$DRY_RUN" == "true" ]] && echo "(dry run)"

# Build branch list
if [[ -n "$BRANCHES" ]]; then
  mapfile -t branch_list <<< "$(tr ' ' '\n' <<< "$BRANCHES" | grep -v '^$')"
else
  mapfile -t branch_list <<< "$(list_source_branches)"
fi

echo "Branches to process: ${#branch_list[@]}"

for branch in "${branch_list[@]}"; do
  # Get SHA from source
  src_sha=$(get_branch_sha "$SOURCE_REPO" "$branch")
  if [[ -z "$src_sha" ]]; then
    echo "  SKIP $branch — not found in ${SOURCE_REPO}"
    (( skipped++ ))
    continue
  fi

  # Check if branch exists in target
  dst_sha=$(get_branch_sha "$TARGET_REPO" "$branch")

  if [[ "$src_sha" == "$dst_sha" ]]; then
    echo "  OK   $branch (already at ${src_sha:0:8})"
    (( skipped++ ))
    continue
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    if [[ -z "$dst_sha" ]]; then
      echo "  DRY  CREATE $branch → ${src_sha:0:8}"
    else
      echo "  DRY  UPDATE $branch ${dst_sha:0:8} → ${src_sha:0:8}"
    fi
    (( synced++ ))
    continue
  fi

  if [[ -z "$dst_sha" ]]; then
    # Create new branch
    payload=$(jq -n --arg ref "refs/heads/${branch}" --arg sha "$src_sha" \
      '{"ref": $ref, "sha": $sha}')
    if api_post "${API}/repos/${TARGET_REPO}/git/refs" -d "$payload" > /dev/null; then
      echo "  CREATE $branch → ${src_sha:0:8}"
      (( synced++ ))
    else
      echo "  FAIL  CREATE $branch"
      (( failed++ ))
    fi
  else
    # Update existing branch
    payload=$(jq -n --arg sha "$src_sha" '{"sha": $sha, "force": true}')
    if api_patch "${API}/repos/${TARGET_REPO}/git/refs/heads/${branch}" -d "$payload" > /dev/null; then
      echo "  UPDATE $branch ${dst_sha:0:8} → ${src_sha:0:8}"
      (( synced++ ))
    else
      echo "  FAIL  UPDATE $branch"
      (( failed++ ))
    fi
  fi
done

echo ""
echo "Done: ${synced} synced, ${skipped} skipped, ${failed} failed"
[[ "$failed" -eq 0 ]]
