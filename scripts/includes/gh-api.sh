#!/usr/bin/env bash
# scripts/includes/gh-api.sh — shared GitHub API helper
#
# Source this file from any script that needs to call the GitHub REST API:
#
#   source "$(dirname "${BASH_SOURCE[0]}")/includes/gh-api.sh"
#
# Migration: many scripts carry a local gh_get() or gh_api() definition.
# Those should eventually be removed in favour of sourcing this file.
# gh_get() here is the canonical implementation — full retry with
# reset-aware backoff. Scripts with bare curl -sf gh_get() (no retry)
# will get improved behaviour automatically once migrated.
#
# Provides:
#   gh_api METHOD URL [CURL_ARGS...]  — authenticated REST call with rate-limit
#                                       retry and header capture
#   gh_get URL [CURL_ARGS...]         — convenience GET wrapper around gh_api;
#                                       returns body, exits 1 on unrecoverable error
#   gh_api_graphql QUERY              — GraphQL wrapper around gh_api
#   gh_create_repo OWNER NAME         — create a repository for the authenticated
#                                       user or an organization, as appropriate
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

    local curl_status=0
    response=$(curl -sS -w "\n%{http_code}" \
      -X "$method" \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -D "$_GH_API_HEADER_FILE" \
      "$@" \
      "$url" 2>/dev/null) || curl_status=$?

    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    # curl transport failures can leave an empty response or HTTP 000. Never
    # treat either as a successful API call, and avoid numeric comparisons on
    # an invalid status. Retry with bounded backoff just like transient 5xx.
    if (( curl_status != 0 )) || [[ ! "$http_code" =~ ^[0-9]{3}$ || "$http_code" == "000" ]]; then
      (( attempt++ )) || true
      if (( attempt > max_retries )); then
        echo "  [gh-api] transport failure (curl exit ${curl_status:-unknown}, HTTP ${http_code:-missing})" >&2
        [[ -n "$body" ]] && echo "$body" >&2
        return 1
      fi
      echo "  [gh-api] transport failure (curl exit ${curl_status}, HTTP ${http_code:-missing}) — retrying in 10s (attempt ${attempt}/${max_retries})" >&2
      sleep 10
      continue
    fi

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
      echo "  [gh-api] request failed with HTTP ${http_code}" >&2
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
    elif [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
      # Only a 2xx response is success. Keep unhandled client errors and
      # redirects from masquerading as successful API operations.
      echo "  [gh-api] request failed with HTTP ${http_code}" >&2
      echo "$body"
      return 1
    fi

    echo "$body"
    return 0
  done
}

# ── gh_get ────────────────────────────────────────────────────────────────────
# Usage: gh_get URL [CURL_ARGS...]
# Convenience GET wrapper around gh_api. Identical retry/backoff behaviour.
# Prints response body to stdout. Returns 0 on 2xx, 1 on unrecoverable error.
#
# Drop-in replacement for the local gh_get() definitions found in individual
# scripts. Scripts can migrate by sourcing this file and removing their local
# definition — the behaviour is identical to the full-retry variants in
# check-osp-ci.sh and cleanup-branches.sh.
gh_get() {
  local url="$1"
  shift
  gh_api GET "$url" "$@"
}

# ── gh_api_graphql ────────────────────────────────────────────────────────────
# Usage: gh_api_graphql QUERY_STRING
# Wraps gh_api for GraphQL. Prints the full JSON response.
gh_api_graphql() {
  local query="$1"
  local payload response
  payload=$(python3 -c "import sys,json; print(json.dumps({'query': sys.argv[1]}))" "$query") || return 1
  response=$(gh_api POST "${_GH_API}/graphql" \
    -H "Content-Type: application/json" \
    -d "$payload") || return 1

  # GraphQL may return HTTP 200 while reporting application-level errors.
  # Reject malformed JSON and non-empty top-level errors rather than letting
  # callers mistake a transport-level success for a successful query.
  if ! printf '%s' "$response" | python3 -c '
import json, sys
try:
    payload = json.load(sys.stdin)
except Exception as exc:
    print(f"[gh-api] invalid GraphQL JSON response: {exc}", file=sys.stderr)
    raise SystemExit(1)
if not isinstance(payload, dict):
    print("[gh-api] invalid GraphQL response: expected a JSON object", file=sys.stderr)
    raise SystemExit(1)
errors = payload.get("errors", [])
if errors:
    print("[gh-api] GraphQL query returned errors:", file=sys.stderr)
    print(json.dumps(errors, ensure_ascii=False), file=sys.stderr)
    raise SystemExit(1)
'; then
    return 1
  fi

  printf '%s\n' "$response"
}

# ── gh_create_repo ───────────────────────────────────────────────────────────
# Usage: gh_create_repo OWNER NAME
# GitHub uses /user/repos for repositories owned by the authenticated user and
# /orgs/{org}/repos for organization repositories. Selecting the wrong endpoint
# returns a misleading 404, so resolve the authenticated login once and cache it.
# Prints the API response body and preserves gh_api's exit status.
_GH_AUTH_LOGIN="${_GH_AUTH_LOGIN:-}"

gh_resolve_authenticated_login() {
  if [[ -z "$_GH_AUTH_LOGIN" ]]; then
    local auth_json
    auth_json=$(gh_get "${_GH_API}/user") || {
      echo "$auth_json" >&2
      return 1
    }
    _GH_AUTH_LOGIN=$(python3 -c \
      'import json,sys; print(json.load(sys.stdin).get("login", ""))' \
      <<< "$auth_json" 2>/dev/null || true)
    if [[ -z "$_GH_AUTH_LOGIN" ]]; then
      echo '[gh-api] Unable to resolve authenticated GitHub login' >&2
      return 1
    fi
  fi
}

gh_create_repo() {
  local owner="$1" name="$2"

  gh_resolve_authenticated_login || return 1

  local endpoint
  if [[ "$owner" == "$_GH_AUTH_LOGIN" ]]; then
    endpoint="${_GH_API}/user/repos"
  else
    endpoint="${_GH_API}/orgs/${owner}/repos"
  fi

  local payload
  payload=$(python3 -c \
    'import json,sys; print(json.dumps({"name":sys.argv[1],"private":False,"auto_init":False}))' \
    "$name")
  gh_api POST "$endpoint" \
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
    echo "  [gh-api][dry-run] would merge upstream: ${fork}@${branch}" >&2
    return 0
  fi

  local result merge_type
  if ! result=$(gh_api POST "${_GH_API}/repos/${fork}/merge-upstream" \
    -H "Content-Type: application/json" \
    -d "{\\"branch\\":\\"${branch}\\"}"); then
    echo "  [gh-api] merge failed for ${fork}@${branch}: API request failed" >&2
    [[ -n "$result" ]] && echo "$result" >&2
    return 1
  fi

  merge_type=$(echo "$result" \
    | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("merge_type","error"))' \
    2>/dev/null || echo "error")

  case "$merge_type" in
    merge)        echo "  [gh-api] merged:             ${fork}@${branch}" >&2 ;;
    fast-forward) echo "  [gh-api] fast-forwarded:     ${fork}@${branch}" >&2 ;;
    none)         echo "  [gh-api] already up-to-date: ${fork}@${branch}" >&2 ;;
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
  local repo="$1" branch="$2" response sha
  response=$(gh_api GET "${_GH_API}/repos/${repo}/git/ref/heads/${branch}") || {
    echo "[gh-api] unable to resolve ${repo}@${branch}: API request failed" >&2
    return 1
  }

  sha=$(printf '%s' "$response" | python3 -c '
import json, sys
try:
    payload = json.load(sys.stdin)
    sha = payload.get("object", {}).get("sha") if isinstance(payload, dict) else None
    if not isinstance(sha, str) or not sha.strip():
        raise ValueError("response has no object SHA")
except Exception as exc:
    print(f"[gh-api] invalid ref response: {exc}", file=sys.stderr)
    raise SystemExit(1)
print(sha)
') || return 1

  printf '%s\n' "$sha"
}
