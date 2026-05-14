#!/usr/bin/env bash
#
# Rebuilds the `lts` branch on a target repo as a rebase of `all-features`
# onto the synced `master` (upstream default branch).
#
# Strategy:
#   1. Clone the fork.
#   2. Ensure master is up to date (merge-upstream).
#   3. Rebase all-features onto master with -Xours so local changes win
#      on any conflict.
#   4. Force-push the result as `lts`.
#
# Required env vars:
#   GH_TOKEN     – PAT with repo scope (push access to TARGET_REPO)
#   TARGET_REPO  – full repo name, e.g. Interested-Deving-1896/penguins-eggs
#
# Optional env vars:
#   BASE_BRANCH     – branch to rebase onto   (default: master)
#   FEATURE_BRANCH  – branch to rebase        (default: all-features)
#   LTS_BRANCH      – branch to force-push to (default: lts)

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${TARGET_REPO:?TARGET_REPO is required}"

BASE_BRANCH="${BASE_BRANCH:-master}"
FEATURE_BRANCH="${FEATURE_BRANCH:-all-features}"
LTS_BRANCH="${LTS_BRANCH:-lts}"

API="https://api.github.com"
REPO_URL="https://x-access-token:${GH_TOKEN}@github.com/${TARGET_REPO}.git"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# ── helpers ────────────────────────────────────────────────────────────────────

gh_api() {
  local method="$1" url="$2"
  shift 2
  local attempt=0 max_retries=3
  local header_file
  header_file=$(mktemp)
  trap 'rm -f "$header_file"' RETURN

  while true; do
    local response http_code body
    response=$(curl -s -w "\n%{http_code}" \
      -X "$method" \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -D "$header_file" \
      "$@" \
      "$url" 2>/dev/null) || true

    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" == "403" || "$http_code" == "429" ]]; then
      (( attempt++ ))
      if (( attempt > max_retries )); then echo "$body"; return 1; fi
      local reset
      reset=$(grep -i "x-ratelimit-reset:" "$header_file" 2>/dev/null | tr -d '\r' | awk '{print $2}')
      if [[ -n "$reset" && "$reset" =~ ^[0-9]+$ ]]; then
        local now wait_seconds
        now=$(date +%s)
        wait_seconds=$(( reset - now + 5 ))
        if (( wait_seconds > 0 && wait_seconds < 3700 )); then
          echo "  Rate limited. Waiting ${wait_seconds}s..." >&2
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

step() { echo ""; echo "── $* ──"; }

# ── 1. Sync master from upstream via API ──────────────────────────────────────

step "Syncing ${TARGET_REPO}:${BASE_BRANCH} from upstream"
sync_result=$(gh_api POST "${API}/repos/${TARGET_REPO}/merge-upstream" \
  -H "Content-Type: application/json" \
  -d "{\"branch\":\"${BASE_BRANCH}\"}") || {
  echo "  merge-upstream failed: $(echo "$sync_result" | jq -r '.message // empty' 2>/dev/null)"
  echo "  Continuing with current master state."
}
merge_type=$(echo "$sync_result" | jq -r '.merge_type // empty' 2>/dev/null)
case "$merge_type" in
  fast-forward) echo "  master fast-forwarded from upstream." ;;
  none)         echo "  master already up to date." ;;
  merge)        echo "  master merged from upstream." ;;
  *)            echo "  master sync status: ${merge_type:-unknown}" ;;
esac

# ── 2. Clone the repo (shallow enough to be fast, full enough for rebase) ─────

step "Cloning ${TARGET_REPO}"
git clone --no-tags --filter=blob:none "$REPO_URL" "$WORK_DIR/repo" 2>&1
cd "$WORK_DIR/repo"

git config user.email "lts-bot@users.noreply.github.com"
git config user.name  "lts-rebase-bot"

# Fetch both branches explicitly
git fetch origin "${BASE_BRANCH}:${BASE_BRANCH}" "${FEATURE_BRANCH}:${FEATURE_BRANCH}" 2>&1

# ── 3. Check if feature branch exists ─────────────────────────────────────────

if ! git show-ref --verify --quiet "refs/heads/${FEATURE_BRANCH}"; then
  echo "Branch '${FEATURE_BRANCH}' not found in ${TARGET_REPO}. Nothing to do."
  exit 0
fi

# ── 4. Rebase all-features onto master with -Xours ────────────────────────────

step "Rebasing ${FEATURE_BRANCH} onto ${BASE_BRANCH} (conflict strategy: ours)"

git checkout -b "${LTS_BRANCH}" "${FEATURE_BRANCH}" 2>&1

# Count commits to rebase for logging
commit_count=$(git rev-list --count "${BASE_BRANCH}..${FEATURE_BRANCH}" 2>/dev/null || echo "?")
echo "  Commits to rebase: ${commit_count}"

# Run the rebase. -Xours means: when a conflict occurs, keep our (all-features) version.
if git rebase --strategy-option=ours "${BASE_BRANCH}" 2>&1; then
  echo "  Rebase completed cleanly."
else
  # Rebase hit conflicts that -Xours couldn't auto-resolve (e.g. delete/modify).
  # Resolve by accepting ours on every conflicted file, then continue.
  echo "  Rebase paused on conflict — applying 'ours' resolution and continuing."
  while true; do
    # Accept our version of every conflicted file
    conflicted=$(git diff --name-only --diff-filter=U 2>/dev/null || true)
    if [[ -z "$conflicted" ]]; then
      break
    fi
    echo "  Conflicted files:"
    echo "$conflicted" | sed 's/^/    /'
    while IFS= read -r f; do
      git checkout --ours -- "$f" 2>/dev/null || true
      git add -- "$f"
    done <<< "$conflicted"

    if git rebase --continue 2>&1; then
      echo "  Rebase continued successfully."
      break
    fi
    # If rebase --continue itself pauses again, loop back
  done
fi

# ── 5. Force-push lts ─────────────────────────────────────────────────────────

step "Force-pushing ${LTS_BRANCH} to ${TARGET_REPO}"
git push --force-with-lease origin "${LTS_BRANCH}" 2>&1 || \
  git push --force origin "${LTS_BRANCH}" 2>&1

lts_sha=$(git rev-parse HEAD)
base_sha=$(git rev-parse "${BASE_BRANCH}")
echo ""
echo "========================================"
echo " LTS rebase complete"
echo " Repo          : ${TARGET_REPO}"
echo " Base (master) : ${base_sha:0:7}"
echo " LTS tip       : ${lts_sha:0:7}"
echo " Commits on lts: ${commit_count}"
echo "========================================"

exit 0
