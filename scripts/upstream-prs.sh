#!/usr/bin/env bash
#
# Collect open PRs from OSP and OOC mirror orgs and open matching PRs in
# Interested-Deving-1896 (the source of truth), then enable auto-merge so
# they land automatically once CI passes.
#
# Flow:
#   OpenOS-Project-OSP  ──┐
#                          ├─► this script ─► Interested-Deving-1896/<repo>
#   OpenOS-Project-OOC  ──┘
#
# For each open PR found in a mirror org:
#   1. Skip if the upstream repo doesn't exist in Interested-Deving-1896.
#   2. Skip if a PR for the same branch already exists upstream.
#   3. Push the PR's head branch into the upstream repo.
#   4. Open a PR upstream referencing the origin.
#   5. Enable auto-merge (squash) on the upstream PR.
#
# Requires:
#   GH_TOKEN        — PAT with repo + workflow + pull_request scopes on all three owners
#   UPSTREAM_OWNER  — e.g. Interested-Deving-1896
#   MIRROR_ORGS     — space-separated, e.g. "OpenOS-Project-OSP OpenOS-Project-Ecosystem-OOC"
#
set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${UPSTREAM_OWNER:?UPSTREAM_OWNER is required}"
: "${MIRROR_ORGS:?MIRROR_ORGS is required}"

API="https://api.github.com"
AUTH=(-H "Authorization: token ${GH_TOKEN}" -H "Accept: application/vnd.github+json")
PER_PAGE=100

opened=0
skipped=0
failed=0

# ── helpers ──────────────────────────────────────────────────────────────────

sanitize() { sed "s/${GH_TOKEN}/***TOKEN***/g"; }

api_get() {
  curl --disable --silent "${AUTH[@]}" "$@"
}

api_post() {
  local url="$1"; shift
  curl --disable --silent -X POST "${AUTH[@]}" -H "Content-Type: application/json" \
    --data "$1" "$url"
}

api_put() {
  local url="$1"; shift
  curl --disable --silent -X PUT "${AUTH[@]}" -H "Content-Type: application/json" \
    --data "$1" "$url"
}

# Get all open PRs for a repo (handles pagination)
get_open_prs() {
  local org="$1" repo="$2"
  local page=1
  while true; do
    local result
    result=$(api_get "${API}/repos/${org}/${repo}/pulls?state=open&per_page=${PER_PAGE}&page=${page}")
    local count
    count=$(echo "$result" | jq 'if type=="array" then length else 0 end' 2>/dev/null || echo 0)
    [[ "$count" -eq 0 ]] && break
    echo "$result" | jq -c '.[]'
    (( page++ ))
  done
}

# Check if upstream repo exists
upstream_exists() {
  local repo="$1"
  local status
  status=$(curl --disable --silent -o /dev/null -w "%{http_code}" \
    "${AUTH[@]}" "${API}/repos/${UPSTREAM_OWNER}/${repo}")
  [[ "$status" == "200" ]]
}

# Check if a PR for this branch already exists upstream
upstream_pr_exists() {
  local repo="$1" branch="$2"
  local count
  count=$(api_get "${API}/repos/${UPSTREAM_OWNER}/${repo}/pulls?state=open&head=${UPSTREAM_OWNER}:${branch}&per_page=1" | \
    jq 'if type=="array" then length else 0 end' 2>/dev/null || echo 0)
  [[ "$count" -gt 0 ]]
}

# Push the PR branch from mirror into upstream
push_branch() {
  local mirror_org="$1" repo="$2" branch="$3"
  local tmpdir
  tmpdir=$(mktemp -d)
  local clone_url="https://x-access-token:${GH_TOKEN}@github.com/${mirror_org}/${repo}.git"
  local upstream_url="https://x-access-token:${GH_TOKEN}@github.com/${UPSTREAM_OWNER}/${repo}.git"

  if ! git clone --bare --branch "$branch" --single-branch "$clone_url" "${tmpdir}/${repo}.git" \
      2>&1 | sanitize; then
    rm -rf "$tmpdir"
    return 1
  fi

  cd "${tmpdir}/${repo}.git" || return 1
  if ! git push "$upstream_url" "refs/heads/${branch}:refs/heads/${branch}" --force \
      2>&1 | sanitize; then
    cd /
    rm -rf "$tmpdir"
    return 1
  fi

  cd /
  rm -rf "$tmpdir"
  return 0
}

# Open a PR upstream
open_upstream_pr() {
  local repo="$1" branch="$2" title="$3" body="$4" base="$5"
  local payload
  payload=$(jq -n \
    --arg title "$title" \
    --arg body  "$body" \
    --arg head  "$branch" \
    --arg base  "$base" \
    '{title: $title, body: $body, head: $head, base: $base}')
  api_post "${API}/repos/${UPSTREAM_OWNER}/${repo}/pulls" "$payload"
}

# Enable auto-merge on a PR (squash strategy)
enable_auto_merge() {
  local repo="$1" pr_number="$2"
  # GraphQL is required for auto-merge
  local pr_node_id
  pr_node_id=$(api_get "${API}/repos/${UPSTREAM_OWNER}/${repo}/pulls/${pr_number}" | \
    jq -r '.node_id // empty')
  [[ -z "$pr_node_id" ]] && return 1

  local query
  query=$(jq -n --arg id "$pr_node_id" \
    '{query: "mutation { enablePullRequestAutoMerge(input: {pullRequestId: \($id), mergeMethod: SQUASH}) { pullRequest { autoMergeRequest { mergeMethod } } } }"}')

  curl --disable --silent -X POST \
    "${AUTH[@]}" \
    -H "Content-Type: application/json" \
    --data "$query" \
    "https://api.github.com/graphql" | jq -r '.data.enablePullRequestAutoMerge.pullRequest.autoMergeRequest.mergeMethod // .errors[0].message // "unknown"'
}

# ── main ─────────────────────────────────────────────────────────────────────

echo "Validating token..."
remaining=$(api_get "${API}/rate_limit" | jq -r '.resources.core.remaining // empty')
[[ -z "$remaining" ]] && { echo "ERROR: GH_TOKEN invalid or missing permissions."; exit 1; }
echo "Token valid. Core API requests remaining: $remaining"
echo ""

for mirror_org in $MIRROR_ORGS; do
  echo "════════════════════════════════════════"
  echo "Scanning PRs in ${mirror_org}..."
  echo "════════════════════════════════════════"

  # Get all repos in the mirror org
  page=1
  while true; do
    repos=$(api_get "${API}/orgs/${mirror_org}/repos?type=all&per_page=${PER_PAGE}&page=${page}" | \
      jq -r '.[].name' 2>/dev/null)
    [[ -z "$repos" ]] && break

    while IFS= read -r repo; do
      [[ -z "$repo" ]] && continue

      # Skip if no upstream counterpart
      if ! upstream_exists "$repo"; then
        continue
      fi

      # Get open PRs
      while IFS= read -r pr_json; do
        [[ -z "$pr_json" ]] && continue

        pr_number=$(echo "$pr_json" | jq -r '.number')
        pr_title=$(echo  "$pr_json" | jq -r '.title')
        pr_branch=$(echo "$pr_json" | jq -r '.head.ref')
        pr_base=$(echo   "$pr_json" | jq -r '.base.ref')
        pr_url=$(echo    "$pr_json" | jq -r '.html_url')
        pr_body=$(echo   "$pr_json" | jq -r '.body // ""')

        echo ""
        echo "  PR #${pr_number}: ${pr_title}"
        echo "  Branch: ${pr_branch} → ${pr_base}"
        echo "  Origin: ${pr_url}"

        # Skip if upstream PR already exists for this branch
        if upstream_pr_exists "$repo" "$pr_branch"; then
          echo "  → already upstreamed, skipping"
          (( skipped++ )) || true
          continue
        fi

        # Push branch upstream
        echo "  → pushing branch to ${UPSTREAM_OWNER}/${repo}..."
        if ! push_branch "$mirror_org" "$repo" "$pr_branch" 2>&1 | sanitize; then
          echo "  → ERROR: failed to push branch"
          (( failed++ )) || true
          continue
        fi

        # Build upstream PR body
        upstream_body="$(printf 'Upstreamed from %s#%s.\n\n---\n\n%s' "$mirror_org/${repo}" "$pr_number" "$pr_body")"

        # Open upstream PR
        echo "  → opening PR in ${UPSTREAM_OWNER}/${repo}..."
        pr_response=$(open_upstream_pr "$repo" "$pr_branch" "$pr_title" "$upstream_body" "$pr_base")
        upstream_pr_number=$(echo "$pr_response" | jq -r '.number // empty')

        if [[ -z "$upstream_pr_number" ]]; then
          echo "  → ERROR: failed to open PR: $(echo "$pr_response" | jq -r '.message // .')"
          (( failed++ )) || true
          continue
        fi

        echo "  → opened ${UPSTREAM_OWNER}/${repo}#${upstream_pr_number}"

        # Enable auto-merge
        echo "  → enabling auto-merge..."
        merge_result=$(enable_auto_merge "$repo" "$upstream_pr_number")
        echo "  → auto-merge: $merge_result"

        (( opened++ )) || true

      done < <(get_open_prs "$mirror_org" "$repo")

    done <<< "$repos"

    (( page++ ))
  done
done

echo ""
echo "════════════════════════════════════════"
echo "  Upstream PR sync complete"
echo "  PRs opened:  ${opened}"
echo "  PRs skipped: ${skipped}"
echo "  PRs failed:  ${failed}"
echo "════════════════════════════════════════"

[[ "$failed" -gt 0 ]] && exit 1
exit 0
