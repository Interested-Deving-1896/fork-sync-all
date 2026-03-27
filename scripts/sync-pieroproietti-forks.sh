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
  local fork="$1" branch="$2"
  local result
  result=$(gh_api POST "${API}/repos/${fork}/merge-upstream" \
    -H "Content-Type: application/json" \
    -d "{\"branch\":\"${branch}\"}") || {
    local msg
    msg=$(echo "$result" | jq -r '.message // empty' 2>/dev/null)
    echo "  failed: ${msg:-unknown error}"
    return 1
  }

  local merge_type
  merge_type=$(echo "$result" | jq -r '.merge_type // empty' 2>/dev/null)
  case "$merge_type" in
    fast-forward) echo "  fast-forwarded." ;;
    none)         echo "  already up to date." ;;
    merge)        echo "  merged." ;;
    *)
      local message
      message=$(echo "$result" | jq -r '.message // empty' 2>/dev/null)
      if [[ -n "$message" && "$message" != "null" ]]; then
        echo "  failed: ${message}"
        return 1
      fi
      ;;
  esac
  return 0
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
  sync_default_branch "$fork" "$upstream_branch" || rc=$?
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
