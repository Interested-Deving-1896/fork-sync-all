#!/usr/bin/env bash
# scripts/includes/gh-api.sh — shared GitHub API helper
#
# Source this file from any script that needs to call the GitHub REST API:
#
#   source "$(dirname "${BASH_SOURCE[0]}")/includes/gh-api.sh"
#
# Provides:
#   gh_api METHOD URL [CURL_ARGS...]  — authenticated REST call with rate-limit
#                                       retry and header capture
#   gh_api_graphql QUERY              — GraphQL wrapper around gh_api
#   merge_upstream FORK BRANCH        — POST merge-upstream for a GitHub fork
#   get_default_sha REPO BRANCH       — resolve a branch ref to its commit SHA
#
# Requires:
#   GH_TOKEN   — set before sourcing; must be a valid PAT
#
# Sets:
#   _GH_API_HEADER_FILE  — temp file for response headers (cleaned up on EXIT
#                          if this file sets the trap; callers that set their
#                          own EXIT trap must clean it up themselves via
#                          rm -f "$_GH_API_HEADER_FILE")
#
# Rate-limit behaviour:
#   HTTP 403/429: reads X-RateLimit-Reset, sleeps until reset (max 3 retries)
#   HTTP 5xx:     retries with 10s backoff (max 3 retries)
#   HTTP 404/409/422: returns body and exits with status 1 immediately

# Guard against double-sourcing
[[ -n "${_GH_API_LOADED:-}" ]] && return 0
_GH_API_LOADED=1

: "${GH_TOKEN:?GH_TOKEN must be set before sourcing gh-api.sh}"

_GH_API="https://api.github.com"
_GH_API_HEADER_FILE=$(mktemp)

# Clean up header file on exit — only if no trap is already set by the caller.
# Callers that set their own EXIT trap should add:
#   trap 'rm -f "$_GH_API_HEADER_FILE"' EXIT
if [[ "$(trap -p EXIT)" == "" ]]; then
  trap 'rm -f "$_GH_API_HEADER_FILE"' EXIT
fi

# ── gh_api ────────────────────────────────────────────────────────────────────
# Usage: gh_api METHOD URL [CURL_ARGS...]
# Prints response body to stdout. Returns 0 on 2xx, 1 on unrecoverable error.
gh_api() {
  local method="$1" url="$2"
  shift 2

  local max_retries=3
  local attempt=0

  while true; do
    local response http_code body

    response=$(curl -s -w "\n%{http_code}" \
      -X "$method" \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -D "$_GH_API_HEADER_FILE" \
      "$@" \
      "$url" 2>/dev/null) || true

    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" == "403" || "$http_code" == "429" ]]; then
      (( attempt++ )) || true
      if (( attempt > max_retries )); then
        echo "$body"
        return 1
      fi
      local reset now wait_seconds
      reset=$(grep -i "x-ratelimit-reset:" "$_GH_API_HEADER_FILE" 2>/dev/null \
              | tr -d '\r' | awk '{print $2}')
      now=$(date +%s)
      wait_seconds=$(( ${reset:-0} - now + 5 ))
      if [[ "$wait_seconds" -gt 0 && "$wait_seconds" -lt 3700 ]]; then
        echo "  [gh-api] rate limited — waiting ${wait_seconds}s (attempt ${attempt}/${max_retries})" >&2
        sleep "$wait_seconds"
      else
        echo "  [gh-api] rate limited — backing off 60s (attempt ${attempt}/${max_retries})" >&2
        sleep 60
      fi
      continue

    elif [[ "$http_code" == "404" || "$http_code" == "409" || "$http_code" == "422" ]]; then
      echo "$body"
      return 1

    elif [[ "$http_code" -ge 500 ]]; then
      (( attempt++ )) || true
      if (( attempt > max_retries )); then
        echo "$body"
        return 1
      fi
      echo "  [gh-api] server error ${http_code} — retrying in 10s (attempt ${attempt}/${max_retries})" >&2
      sleep 10
      continue
    fi

    echo "$body"
    return 0
  done
}

# ── gh_api_graphql ────────────────────────────────────────────────────────────
# Usage: gh_api_graphql QUERY_STRING
# Wraps gh_api for GraphQL. Prints the full JSON response.
gh_api_graphql() {
  local query="$1"
  local payload
  payload=$(python3 -c "import sys,json; print(json.dumps({'query': sys.argv[1]}))" "$query")
  gh_api POST "${_GH_API}/graphql" \
    -H "Content-Type: application/json" \
    -d "$payload"
}

# ── merge_upstream ────────────────────────────────────────────────────────────
# Usage: merge_upstream FORK_REPO BRANCH [DRY_RUN]
# Fast-forwards FORK_REPO/BRANCH to its upstream HEAD via the GitHub API.
# FORK_REPO format: owner/repo
# Returns 0 on success or already-up-to-date, 1 on unrecoverable divergence.
merge_upstream() {
  local fork="$1" branch="$2" dry="${3:-${DRY_RUN:-false}}"

  if [[ "$dry" == "true" ]]; then
    echo "  [gh-api][dry-run] would merge upstream: ${fork}@${branch}"
    return 0
  fi

  local result merge_type
  result=$(gh_api POST "${_GH_API}/repos/${fork}/merge-upstream" \
    -H "Content-Type: application/json" \
    -d "{\"branch\":\"${branch}\"}" 2>&1) || true

  merge_type=$(echo "$result" \
    | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("merge_type","error"))' \
    2>/dev/null || echo "error")

  case "$merge_type" in
    merge)        echo "  [gh-api] merged:            ${fork}@${branch}" ;;
    fast-forward) echo "  [gh-api] fast-forwarded:    ${fork}@${branch}" ;;
    none)         echo "  [gh-api] already up-to-date: ${fork}@${branch}" ;;
    *)
      local msg
      msg=$(echo "$result" \
        | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("message","?"))' \
        2>/dev/null || echo "$result")
      echo "  [gh-api] merge failed for ${fork}@${branch}: ${msg}" >&2
      return 1
      ;;
  esac
  return 0
}

# ── get_default_sha ───────────────────────────────────────────────────────────
# Usage: get_default_sha REPO BRANCH
# Prints the commit SHA at REPO/BRANCH HEAD, or empty string on failure.
get_default_sha() {
  local repo="$1" branch="$2"
  gh_api GET "${_GH_API}/repos/${repo}/git/ref/heads/${branch}" \
    | python3 -c \
      'import sys,json; d=json.load(sys.stdin); print(d.get("object",{}).get("sha",""))' \
    2>/dev/null || echo ""
}
