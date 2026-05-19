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
#
# Uses merge-upstream API first. If the fork reports "already up to date" but
# is still behind (can happen when fork default branch != BASE_BRANCH), falls
# back to fetching directly from the upstream parent and pushing.

step "Syncing ${TARGET_REPO}:${BASE_BRANCH} from upstream"

# Resolve the upstream parent repo
upstream_repo=$(gh_api GET "${API}/repos/${TARGET_REPO}" \
  | jq -r '.parent.full_name // empty' 2>/dev/null)
echo "  Upstream parent: ${upstream_repo:-unknown}"

sync_result=$(gh_api POST "${API}/repos/${TARGET_REPO}/merge-upstream" \
  -H "Content-Type: application/json" \
  -d "{\"branch\":\"${BASE_BRANCH}\"}") || true
merge_type=$(echo "$sync_result" | jq -r '.merge_type // empty' 2>/dev/null)
case "$merge_type" in
  fast-forward) echo "  ${BASE_BRANCH} fast-forwarded from upstream." ;;
  none)         echo "  ${BASE_BRANCH} already up to date (API)." ;;
  merge)        echo "  ${BASE_BRANCH} merged from upstream." ;;
  *)            echo "  ${BASE_BRANCH} sync status: ${merge_type:-unknown}" ;;
esac

# ── Helper: rebase current HEAD onto base, resolving conflicts with -Xours ────
# Call after checking out the branch to rebase. Does not capture output.

do_rebase() {
  local base="$1"
  local commit_count
  commit_count=$(git rev-list --count "${base}..HEAD" 2>/dev/null || echo "?")
  echo "  Commits to rebase: ${commit_count}"

  if git rebase --strategy-option=ours "${base}" 2>&1; then
    echo "  Rebase completed cleanly."
  else
    echo "  Rebase paused on conflict — applying 'ours' resolution and continuing."
    while true; do
      local conflicted
      conflicted=$(git diff --name-only --diff-filter=U 2>/dev/null || true)
      [[ -z "$conflicted" ]] && break
      echo "  Conflicted files:"
      echo "$conflicted" | sed 's/^/    /'
      while IFS= read -r f; do
        git checkout --ours -- "$f" 2>/dev/null || true
        git add -- "$f"
      done <<< "$conflicted"
      git rebase --continue 2>&1 && { echo "  Rebase continued successfully."; break; }
    done
  fi
}

# ── 2. Clone the repo ─────────────────────────────────────────────────────────

step "Cloning ${TARGET_REPO}"
# Clone checking out BASE_BRANCH explicitly so FEATURE_BRANCH is not checked
# out — this allows us to fetch into FEATURE_BRANCH without git refusing.
git clone --no-tags --branch "${BASE_BRANCH}" "$REPO_URL" "$WORK_DIR/repo" 2>&1
cd "$WORK_DIR/repo"

git config user.email "lts-bot@users.noreply.github.com"
git config user.name  "lts-rebase-bot"

# Fetch FEATURE_BRANCH and LTS_BRANCH as local tracking branches.
git fetch origin "${FEATURE_BRANCH}:${FEATURE_BRANCH}" 2>&1
git fetch origin "${LTS_BRANCH}:${LTS_BRANCH}" 2>&1 || true  # lts may not exist yet

# Ensure BASE_BRANCH is truly current from the upstream parent.
# merge-upstream may report "already up to date" if the fork's default branch
# differs from BASE_BRANCH — fetch directly from upstream as a safety net.
if [[ -n "$upstream_repo" ]]; then
  upstream_url="https://github.com/${upstream_repo}.git"
  echo "  Fetching ${BASE_BRANCH} directly from ${upstream_repo}..."
  git fetch "$upstream_url" "${BASE_BRANCH}:refs/remotes/upstream/${BASE_BRANCH}" 2>&1 || true
  if git show-ref --verify --quiet "refs/remotes/upstream/${BASE_BRANCH}"; then
    local_sha=$(git rev-parse "${BASE_BRANCH}")
    upstream_sha=$(git rev-parse "upstream/${BASE_BRANCH}")
    if [[ "$local_sha" != "$upstream_sha" ]]; then
      echo "  Local ${BASE_BRANCH} (${local_sha:0:7}) differs from upstream (${upstream_sha:0:7}) — updating."
      git reset --hard "upstream/${BASE_BRANCH}" 2>&1
      git push --force-with-lease origin "${BASE_BRANCH}" 2>&1 || \
        git push --force origin "${BASE_BRANCH}" 2>&1
      echo "  ${BASE_BRANCH} updated to upstream tip."
    else
      echo "  ${BASE_BRANCH} is current with upstream."
    fi
  fi
fi

# ── 3. Check if feature branch exists ─────────────────────────────────────────

if ! git show-ref --verify --quiet "refs/heads/${FEATURE_BRANCH}"; then
  echo "Branch '${FEATURE_BRANCH}' not found in ${TARGET_REPO}. Nothing to do."
  exit 0
fi

# ── 4. Rebase all-features onto master in place ───────────────────────────────
#
# Checks out all-features, rebases onto master, force-pushes.
# Conflicts resolved with -Xours (our changes win).

step "Rebasing ${FEATURE_BRANCH} onto ${BASE_BRANCH} in place (conflict strategy: ours)"
git checkout "${FEATURE_BRANCH}" 2>&1
# Use explicit SHA to guarantee we rebase onto the actual current tip,
# not a potentially stale symbolic ref.
base_tip=$(git rev-parse "${BASE_BRANCH}")
echo "  Rebasing onto ${BASE_BRANCH} tip: ${base_tip:0:7}"
do_rebase "$base_tip"

step "Force-pushing ${FEATURE_BRANCH} to ${TARGET_REPO}"
git push --force-with-lease origin "${FEATURE_BRANCH}" 2>&1 || \
  git push --force origin "${FEATURE_BRANCH}" 2>&1
feature_sha=$(git rev-parse HEAD)

# ── 5. Build lts from the freshly rebased all-features ────────────────────────
#
# Check out a new lts branch from the current (rebased) all-features HEAD
# and force-push it as lts. No second rebase needed — all-features is already
# on top of master.

step "Building ${LTS_BRANCH} from rebased ${FEATURE_BRANCH}"
git checkout -B "${LTS_BRANCH}" HEAD 2>&1

step "Force-pushing ${LTS_BRANCH} to ${TARGET_REPO}"
git push --force origin "${LTS_BRANCH}" 2>&1
lts_sha=$(git rev-parse HEAD)
base_sha=$(git rev-parse "${BASE_BRANCH}")

commit_count=$(git rev-list --count "${BASE_BRANCH}..${FEATURE_BRANCH}" 2>/dev/null || echo "?")
echo ""
echo "========================================"
echo " Rebase complete"
echo " Repo             : ${TARGET_REPO}"
echo " Base (${BASE_BRANCH})  : ${base_sha:0:7}"
echo " ${FEATURE_BRANCH} tip  : ${feature_sha:0:7} (${commit_count} commits ahead)"
echo " ${LTS_BRANCH} tip      : ${lts_sha:0:7}"
echo "========================================"

exit 0
