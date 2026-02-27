#!/usr/bin/env bash
#
# Syncs all branches of every fork owned by GITHUB_OWNER with their upstream.
# Requires: GH_TOKEN (PAT with public_repo scope), GITHUB_OWNER, curl, jq.
#
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_OWNER:?GITHUB_OWNER is required}"

API="https://api.github.com"
PER_PAGE=100

# Counters
synced=0
failed=0
skipped=0

# ── helpers ──────────────────────────────────────────────────────────────────

gh_api() {
  # Makes an authenticated GitHub API request.
  # Handles rate limiting by sleeping until the reset window.
  local method="$1" url="$2"
  shift 2

  while true; do
    local response http_code headers body
    response=$(curl -s -w "\n%{http_code}" \
      -X "$method" \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -D /dev/stderr \
      "$@" \
      "$url" 2>/tmp/gh_headers)

    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')
    headers=$(cat /tmp/gh_headers)

    if [[ "$http_code" == "403" || "$http_code" == "429" ]]; then
      local reset
      reset=$(echo "$headers" | grep -i "x-ratelimit-reset:" | tr -d '\r' | awk '{print $2}')
      if [[ -n "$reset" ]]; then
        local now wait_seconds
        now=$(date +%s)
        wait_seconds=$(( reset - now + 5 ))
        if (( wait_seconds > 0 && wait_seconds < 3700 )); then
          echo "  ⚠️  Rate limited. Waiting ${wait_seconds}s until reset..."
          sleep "$wait_seconds"
          continue
        fi
      fi
      # Secondary rate limit — back off 60s
      echo "  ⚠️  Rate limited (no reset header). Backing off 60s..."
      sleep 60
      continue
    fi

    echo "$body"
    return 0
  done
}

get_all_forks() {
  # Paginates through all repos for the owner, filtering to forks only.
  local page=1
  while true; do
    local result
    result=$(gh_api GET "${API}/users/${GITHUB_OWNER}/repos?type=forks&per_page=${PER_PAGE}&page=${page}&sort=full_name")

    local count
    count=$(echo "$result" | jq 'length')

    if [[ "$count" == "0" || "$count" == "null" ]]; then
      break
    fi

    echo "$result" | jq -r '.[] | .full_name'
    (( page++ ))
  done
}

get_upstream_repo() {
  # Returns the upstream (parent) full_name for a fork.
  local fork="$1"
  gh_api GET "${API}/repos/${fork}" | jq -r '.parent.full_name // empty'
}

get_branches() {
  # Lists all branch names for a repo (paginated).
  local repo="$1"
  local page=1
  while true; do
    local result
    result=$(gh_api GET "${API}/repos/${repo}/branches?per_page=${PER_PAGE}&page=${page}")

    local count
    count=$(echo "$result" | jq 'length')
    if [[ "$count" == "0" || "$count" == "null" ]]; then
      break
    fi

    echo "$result" | jq -r '.[].name'
    (( page++ ))
  done
}

sync_branch() {
  # Syncs a single branch of a fork with the same branch on upstream.
  # Uses the merge-upstream API for the default branch, and
  # compare + merge for non-default branches.
  local fork="$1" branch="$2" upstream="$3" is_default="$4"

  if [[ "$is_default" == "true" ]]; then
    # The merge-upstream endpoint only works on the default branch
    local result
    result=$(gh_api POST "${API}/repos/${fork}/merge-upstream" \
      -d "{\"branch\":\"${branch}\"}")

    local message
    message=$(echo "$result" | jq -r '.message // empty')
    local merge_type
    merge_type=$(echo "$result" | jq -r '.merge_type // empty')

    if [[ "$merge_type" == "fast-forward" || "$merge_type" == "none" ]]; then
      return 0
    elif [[ -n "$message" ]]; then
      echo "    ❌ ${branch}: ${message}"
      return 1
    else
      return 0
    fi
  else
    # For non-default branches: check if upstream has this branch,
    # then use the merges API to pull upstream changes.
    # First verify the branch exists upstream.
    local upstream_check
    upstream_check=$(gh_api GET "${API}/repos/${upstream}/branches/${branch}" 2>/dev/null || true)
    local upstream_sha
    upstream_sha=$(echo "$upstream_check" | jq -r '.commit.sha // empty')

    if [[ -z "$upstream_sha" ]]; then
      # Branch doesn't exist upstream — skip silently
      return 2
    fi

    # Check if fork branch is already up to date by comparing
    local compare
    compare=$(gh_api GET "${API}/repos/${fork}/compare/${branch}...${upstream}:${branch}")
    local status_val
    status_val=$(echo "$compare" | jq -r '.status // empty')

    if [[ "$status_val" == "identical" || "$status_val" == "behind" ]]; then
      # Already up to date, or upstream is behind fork
      return 0
    fi

    # Attempt a merge via the merges API
    local merge_result
    merge_result=$(gh_api POST "${API}/repos/${fork}/merges" \
      -d "{\"base\":\"${branch}\",\"head\":\"${upstream_sha}\",\"commit_message\":\"Sync branch ${branch} from upstream ${upstream}\"}")

    local merge_sha
    merge_sha=$(echo "$merge_result" | jq -r '.sha // empty')
    local merge_msg
    merge_msg=$(echo "$merge_result" | jq -r '.message // empty')

    if [[ -n "$merge_sha" ]]; then
      return 0
    elif [[ "$merge_msg" == *"Merge conflict"* || "$merge_msg" == *"merge conflict"* ]]; then
      echo "    ❌ ${branch}: merge conflict"
      return 1
    elif [[ -n "$merge_msg" ]]; then
      echo "    ❌ ${branch}: ${merge_msg}"
      return 1
    fi
    return 0
  fi
}

# ── main ─────────────────────────────────────────────────────────────────────

echo "Fetching all forks for ${GITHUB_OWNER}..."
mapfile -t forks < <(get_all_forks)
echo "Found ${#forks[@]} forks."
echo ""

for fork in "${forks[@]}"; do
  echo "Syncing ${fork}..."

  upstream=$(get_upstream_repo "$fork")
  if [[ -z "$upstream" ]]; then
    echo "  ⚠️  No upstream found, skipping."
    (( skipped++ ))
    continue
  fi

  # Get the default branch name
  default_branch=$(gh_api GET "${API}/repos/${fork}" | jq -r '.default_branch')

  # Get all branches of the fork
  mapfile -t branches < <(get_branches "$fork")

  repo_ok=true
  for branch in "${branches[@]}"; do
    is_default="false"
    [[ "$branch" == "$default_branch" ]] && is_default="true"

    result_code=0
    sync_branch "$fork" "$branch" "$upstream" "$is_default" || result_code=$?

    if [[ "$result_code" == "0" ]]; then
      (( synced++ ))
    elif [[ "$result_code" == "2" ]]; then
      # Branch doesn't exist upstream — not counted
      :
    else
      (( failed++ ))
      repo_ok=false
    fi
  done

  if $repo_ok; then
    echo "  ✅ All branches synced."
  fi
done

echo ""
echo "════════════════════════════════════════"
echo "  Sync complete"
echo "  Branches synced:   ${synced}"
echo "  Branches failed:   ${failed}"
echo "  Repos skipped:     ${skipped}"
echo "════════════════════════════════════════"

if (( failed > 0 )); then
  exit 1
fi
