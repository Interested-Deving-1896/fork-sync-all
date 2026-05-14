#!/usr/bin/env bash
#
# Syncs all Interested-Deving-1896 forks whose upstream is pieroproietti/*.
# Runs on a tight budget (50 min) to fit inside the hourly schedule.
#
# Required env vars:
#   GH_TOKEN      – PAT with public_repo scope
#   GITHUB_OWNER  – fork owner (Interested-Deving-1896)
#   UPSTREAM_USER – upstream owner to filter on (pieroproietti)

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_OWNER:?GITHUB_OWNER is required}"
: "${UPSTREAM_USER:=pieroproietti}"

API="https://api.github.com"
PER_PAGE=100
HEADER_FILE=$(mktemp)
trap 'rm -f "$HEADER_FILE"' EXIT

synced=0
failed=0
skipped=0

# ── helpers ────────────────────────────────────────────────────────────────────

gh_api() {
  local method="$1" url="$2"
  shift 2
  local attempt=0 max_retries=3

  while true; do
    local response http_code body
    response=$(curl -s -w "\n%{http_code}" \
      -X "$method" \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -D "$HEADER_FILE" \
      "$@" \
      "$url" 2>/dev/null) || true

    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" == "403" || "$http_code" == "429" ]]; then
      (( attempt++ ))
      if (( attempt > max_retries )); then echo "$body"; return 1; fi
      local reset
      reset=$(grep -i "x-ratelimit-reset:" "$HEADER_FILE" 2>/dev/null | tr -d '\r' | awk '{print $2}')
      if [[ -n "$reset" && "$reset" =~ ^[0-9]+$ ]]; then
        local now wait_seconds
        now=$(date +%s)
        wait_seconds=$(( reset - now + 5 ))
        if (( wait_seconds > 0 && wait_seconds < 3700 )); then
          echo "  Rate limited. Waiting ${wait_seconds}s until reset..." >&2
          sleep "$wait_seconds"
          continue
        fi
      fi
      echo "  Rate limited. Backing off 60s..." >&2
      sleep 60
      continue
    elif [[ "$http_code" == "404" || "$http_code" == "409" || "$http_code" == "422" ]]; then
      echo "$body"; return 1
    elif [[ "$http_code" -ge 500 ]]; then
      (( attempt++ ))
      if (( attempt > max_retries )); then echo "$body"; return 1; fi
      echo "  Server error ($http_code). Retrying in 10s..." >&2
      sleep 10
      continue
    fi

    echo "$body"
    return 0
  done
}

# Fetch all forks of GITHUB_OWNER whose parent is UPSTREAM_USER/*.
get_pieroproietti_forks() {
  local page=1
  while true; do
    local result
    result=$(gh_api GET \
      "${API}/users/${GITHUB_OWNER}/repos?type=forks&per_page=${PER_PAGE}&page=${page}&sort=full_name") || break

    local count
    count=$(echo "$result" | jq 'length' 2>/dev/null) || break
    [[ -z "$count" || "$count" == "0" || "$count" == "null" ]] && break

    # Emit only forks whose upstream owner matches UPSTREAM_USER.
    # Use the upstream's default_branch (not the fork's) as the branch to sync —
    # the fork may have a different default branch (e.g. all-features vs master).
    echo "$result" | jq -r \
      --arg upstream "$UPSTREAM_USER" \
      '.[] | select(.parent.owner.login == $upstream) | "\(.full_name) \(.parent.default_branch) \(.parent.full_name)"' \
      2>/dev/null

    (( page++ ))
  done
}

sync_default_branch() {
  local fork="$1" branch="$2" upstream="$3"
  local result
  result=$(gh_api POST "${API}/repos/${fork}/merge-upstream" \
    -H "Content-Type: application/json" \
    -d "{\"branch\":\"${branch}\"}") || true

  local merge_type message
  merge_type=$(echo "$result" | jq -r '.merge_type // empty' 2>/dev/null)
  message=$(echo "$result"   | jq -r '.message   // empty' 2>/dev/null)

  case "$merge_type" in
    fast-forward) echo "  fast-forwarded." ; return 0 ;;
    none)         echo "  already up to date." ; return 0 ;;
    merge)        echo "  merged." ; return 0 ;;
  esac

  # merge-upstream failed — likely diverged. Force-reset to upstream HEAD.
  echo "  merge-upstream failed (${message:-no merge_type returned}). Attempting force-reset to upstream HEAD..."
  force_reset_to_upstream "$fork" "$branch" "$upstream"
}

# Resolves the upstream branch SHA and force-updates the fork's ref to match.
force_reset_to_upstream() {
  local fork="$1" branch="$2" upstream="$3"

  # Get upstream branch SHA
  local upstream_ref
  upstream_ref=$(gh_api GET "${API}/repos/${upstream}/git/ref/heads/${branch}") || {
    echo "  force-reset failed: could not fetch upstream ref for ${upstream}:${branch}"
    return 1
  }
  local upstream_sha
  upstream_sha=$(echo "$upstream_ref" | jq -r '.object.sha // empty' 2>/dev/null)
  if [[ -z "$upstream_sha" || "$upstream_sha" == "null" ]]; then
    echo "  force-reset failed: could not parse upstream SHA"
    return 1
  fi

  # Force-update the fork's ref
  local patch_result
  patch_result=$(gh_api PATCH "${API}/repos/${fork}/git/refs/heads/${branch}" \
    -H "Content-Type: application/json" \
    -d "{\"sha\":\"${upstream_sha}\",\"force\":true}") || {
    local msg
    msg=$(echo "$patch_result" | jq -r '.message // empty' 2>/dev/null)
    echo "  force-reset failed: ${msg:-unknown error}"
    return 1
  }

  local new_sha
  new_sha=$(echo "$patch_result" | jq -r '.object.sha // empty' 2>/dev/null)
  if [[ -n "$new_sha" && "$new_sha" != "null" ]]; then
    echo "  force-reset to upstream HEAD (${new_sha:0:7})."
    return 0
  fi

  echo "  force-reset failed: unexpected response"
  return 1
}

# ── main ───────────────────────────────────────────────────────────────────────

# Budget: 50 min — leaves 10 min headroom before the 60-min job timeout.
START_TIME=$(date +%s)
BUDGET_SECONDS=$(( 50 * 60 ))

echo "Fetching forks of ${GITHUB_OWNER} whose upstream is ${UPSTREAM_USER}/..."
mapfile -t fork_lines < <(get_pieroproietti_forks)
echo "Found ${#fork_lines[@]} matching fork(s)."
echo ""

total=${#fork_lines[@]}
current=0
timed_out=false

for line in "${fork_lines[@]}"; do
  [[ -z "$line" ]] && continue

  elapsed=$(( $(date +%s) - START_TIME ))
  if (( elapsed >= BUDGET_SECONDS )); then
    echo "Time budget reached after ${elapsed}s — stopping early."
    timed_out=true
    break
  fi

  (( current++ ))
  fork=$(echo "$line"            | awk '{print $1}')
  upstream_branch=$(echo "$line" | awk '{print $2}')
  upstream=$(echo "$line"        | awk '{print $3}')

  [[ -z "$fork" ]] && continue

  echo "[${current}/${total}] ${fork}  (upstream: ${upstream}, branch: ${upstream_branch})"

  if [[ -z "$upstream" || "$upstream" == "null" ]]; then
    echo "  No upstream found, skipping."
    (( skipped++ ))
    continue
  fi

  if [[ -z "$upstream_branch" || "$upstream_branch" == "null" ]]; then
    echo "  No upstream default branch found, skipping."
    (( skipped++ ))
    continue
  fi

  rc=0
  sync_default_branch "$fork" "$upstream_branch" "$upstream" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    (( synced++ ))
  else
    (( failed++ ))
  fi
done

echo ""
echo "========================================"
echo " pieroproietti fork sync complete"
echo " Repos processed : ${current}/${total}"
if [[ "$timed_out" == "true" ]]; then
  echo " Status          : partial (time budget reached)"
else
  echo " Status          : complete"
fi
echo " Synced          : ${synced}"
echo " Failed          : ${failed}"
echo " Skipped         : ${skipped}"
echo "========================================"

exit 0
