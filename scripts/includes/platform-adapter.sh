#!/usr/bin/env bash
#
# scripts/includes/platform-adapter.sh — git hosting platform abstraction
#
# Provides a uniform interface for interacting with different git hosting
# platforms (GitHub, GitLab, Gitea, Forgejo, Codeberg) so that sync scripts
# can be written once and work against any backend.
#
# ── Supported platforms ───────────────────────────────────────────────────────
#
#   github    — github.com (or GitHub Enterprise via PLATFORM_HOST)
#   gitlab    — gitlab.com (or self-hosted via PLATFORM_HOST)
#   gitea     — any Gitea instance (PLATFORM_HOST required)
#   forgejo   — any Forgejo instance (PLATFORM_HOST required)
#   codeberg  — codeberg.org (Forgejo-based; PLATFORM_HOST defaults to codeberg.org)
#
# ── Configuration env vars ────────────────────────────────────────────────────
#
#   PLATFORM          — one of: github | gitlab | gitea | forgejo | codeberg
#   PLATFORM_HOST     — base URL override (e.g. https://gitlab.mycompany.com)
#                       Defaults to the platform's canonical public host.
#   PLATFORM_TOKEN    — auth token for the platform
#   PLATFORM_ORG      — org/group/namespace to operate on
#
# ── Functions ─────────────────────────────────────────────────────────────────
#
#   pa_init PLATFORM [HOST]
#     Initialise the adapter. Must be called before any other pa_* function.
#     Sets PA_HOST, PA_API, PA_AUTH_HEADER, PA_CLONE_PREFIX.
#
#   pa_list_repos ORG
#     Print one repo name per line for the given org/group/namespace.
#     Handles pagination automatically.
#
#   pa_repo_exists ORG REPO
#     Returns 0 if the repo exists, 1 otherwise.
#
#   pa_clone_url ORG REPO
#     Print the authenticated HTTPS clone URL for the repo.
#
#   pa_push_url ORG REPO
#     Print the authenticated HTTPS push URL for the repo.
#     Same as clone_url for most platforms; separated for clarity.
#
#   pa_create_repo ORG REPO [DESCRIPTION]
#     Create the repo if it doesn't exist. No-op if it already exists.
#     Returns 0 on success or if already exists.
#
#   pa_api_get URL
#     Authenticated GET against the platform API. Handles rate-limit retry
#     (HTTP 429/403) with reset-aware backoff up to 3 attempts.
#     Prints response body on success; empty string on failure.
#
#   pa_rate_limit_remaining
#     Print the number of remaining API calls for the current token.
#     Returns 0 always (best-effort; not all platforms expose this).
#
# Guard against double-sourcing
[[ -n "${_PLATFORM_ADAPTER_LOADED:-}" ]] && return 0
_PLATFORM_ADAPTER_LOADED=1

# ── Internal state ────────────────────────────────────────────────────────────
PA_PLATFORM=""
PA_HOST=""
PA_API=""
PA_AUTH_HEADER=""
PA_CLONE_PREFIX=""   # https://TOKEN@host
_PA_HEADER_TMP=""

_pa_warn() { echo "[platform-adapter][warn] $*" >&2; }
_pa_info() { echo "[platform-adapter] $*" >&2; }

# ── pa_init ───────────────────────────────────────────────────────────────────
pa_init() {
  local platform="${1:-${PLATFORM:-}}"
  local host_override="${2:-${PLATFORM_HOST:-}}"
  local token="${PLATFORM_TOKEN:-${GH_TOKEN:-${GITLAB_TOKEN:-}}}"

  [[ -z "$platform" ]] && { _pa_warn "PLATFORM is required"; return 1; }
  [[ -z "$token"    ]] && { _pa_warn "PLATFORM_TOKEN (or GH_TOKEN/GITLAB_TOKEN) is required"; return 1; }

  PA_PLATFORM="$platform"
  _PA_HEADER_TMP=$(mktemp)
  trap 'rm -f "$_PA_HEADER_TMP"' EXIT

  case "$platform" in
    github)
      PA_HOST="${host_override:-https://github.com}"
      PA_API="${host_override:+${host_override}/api/v3}"; PA_API="${PA_API:-https://api.github.com}"
      PA_AUTH_HEADER="Authorization: token ${token}"
      PA_CLONE_PREFIX="${PA_HOST/https:\/\//https://x-access-token:${token}@}"
      ;;
    gitlab)
      PA_HOST="${host_override:-https://gitlab.com}"
      PA_API="${PA_HOST}/api/v4"
      PA_AUTH_HEADER="PRIVATE-TOKEN: ${token}"
      PA_CLONE_PREFIX="${PA_HOST/https:\/\//https://oauth2:${token}@}"
      ;;
    gitea|forgejo)
      [[ -z "$host_override" ]] && { _pa_warn "${platform}: PLATFORM_HOST is required (no canonical public host)"; return 1; }
      PA_HOST="$host_override"
      PA_API="${PA_HOST}/api/v1"
      PA_AUTH_HEADER="Authorization: token ${token}"
      PA_CLONE_PREFIX="${PA_HOST/https:\/\//https://x-access-token:${token}@}"
      ;;
    codeberg)
      PA_HOST="${host_override:-https://codeberg.org}"
      PA_API="${PA_HOST}/api/v1"
      PA_AUTH_HEADER="Authorization: token ${token}"
      PA_CLONE_PREFIX="${PA_HOST/https:\/\//https://x-access-token:${token}@}"
      ;;
    *)
      _pa_warn "Unknown platform '${platform}'. Supported: github gitlab gitea forgejo codeberg"
      return 1
      ;;
  esac

  _pa_info "Initialised: platform=${PA_PLATFORM} host=${PA_HOST} api=${PA_API}"
}

# ── pa_api_get ────────────────────────────────────────────────────────────────
pa_api_get() {
  local url="$1"
  local max_retries=3 attempt=0

  while true; do
    local out http_code body
    out=$(curl -sf -w "\n%{http_code}" \
      -D "$_PA_HEADER_TMP" \
      -H "$PA_AUTH_HEADER" \
      -H "Accept: application/json" \
      "$url" 2>/dev/null) || true
    http_code=$(echo "$out" | tail -1)
    body=$(echo "$out" | sed '$d')

    if [[ "$http_code" == "429" || "$http_code" == "403" ]]; then
      (( attempt++ )) || true
      if (( attempt > max_retries )); then
        _pa_warn "API GET ${url} failed after ${max_retries} retries (HTTP ${http_code})"
        echo ""
        return 1
      fi
      # Try to read reset time from headers (GitHub: X-RateLimit-Reset, GitLab: RateLimit-Reset)
      local reset now wait=60
      reset=$(grep -i "x-ratelimit-reset:\|ratelimit-reset:" "$_PA_HEADER_TMP" 2>/dev/null \
        | tr -d '\r' | awk '{print $2}' | head -1)
      now=$(date +%s)
      if [[ -n "$reset" && "$reset" =~ ^[0-9]+$ ]]; then
        wait=$(( reset - now + 5 ))
        (( wait < 5   )) && wait=5
        (( wait > 3700 )) && wait=60
      fi
      _pa_warn "Rate limited (HTTP ${http_code}) — sleeping ${wait}s (attempt ${attempt}/${max_retries})"
      sleep "$wait"
      continue
    fi

    echo "$body"
    [[ "$http_code" =~ ^2 ]] && return 0
    return 1
  done
}

# ── pa_list_repos ─────────────────────────────────────────────────────────────
pa_list_repos() {
  local org="$1"
  local page=1

  while true; do
    local url repos_json names

    case "$PA_PLATFORM" in
      github)
        # Try org endpoint first; fall back to user repos
        url="${PA_API}/orgs/${org}/repos?per_page=100&page=${page}&type=all"
        repos_json=$(pa_api_get "$url" 2>/dev/null)
        if [[ -z "$repos_json" || "$repos_json" == "[]" ]]; then
          url="${PA_API}/users/${org}/repos?per_page=100&page=${page}&type=all"
          repos_json=$(pa_api_get "$url" 2>/dev/null || echo "[]")
        fi
        names=$(echo "$repos_json" | python3 -c \
          "import sys,json; [print(r['name']) for r in json.load(sys.stdin)]" 2>/dev/null || true)
        ;;
      gitlab)
        # org is a group path (e.g. openos-project or openos-project/core)
        local encoded_org
        encoded_org=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote('${org}',safe=''))")
        url="${PA_API}/groups/${encoded_org}/projects?per_page=100&page=${page}&include_subgroups=false&archived=false"
        repos_json=$(pa_api_get "$url" 2>/dev/null || echo "[]")
        names=$(echo "$repos_json" | python3 -c \
          "import sys,json; [print(r['path']) for r in json.load(sys.stdin)]" 2>/dev/null || true)
        ;;
      gitea|forgejo|codeberg)
        url="${PA_API}/orgs/${org}/repos?limit=50&page=${page}"
        repos_json=$(pa_api_get "$url" 2>/dev/null || echo "[]")
        names=$(echo "$repos_json" | python3 -c \
          "import sys,json; [print(r['name']) for r in json.load(sys.stdin)]" 2>/dev/null || true)
        ;;
    esac

    [[ -z "$names" ]] && break
    echo "$names"

    local count
    count=$(echo "$names" | wc -l)
    # GitHub/GitLab page at 100; Gitea/Forgejo at 50
    local page_size=100
    [[ "$PA_PLATFORM" == "gitea" || "$PA_PLATFORM" == "forgejo" || "$PA_PLATFORM" == "codeberg" ]] && page_size=50
    (( count < page_size )) && break
    (( page++ ))
  done
}

# ── pa_repo_exists ────────────────────────────────────────────────────────────
pa_repo_exists() {
  local org="$1" repo="$2"
  local url result

  case "$PA_PLATFORM" in
    github)          url="${PA_API}/repos/${org}/${repo}" ;;
    gitlab)
      local encoded
      encoded=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${org}/${repo}',safe=''))")
      url="${PA_API}/projects/${encoded}"
      ;;
    gitea|forgejo|codeberg) url="${PA_API}/repos/${org}/${repo}" ;;
  esac

  result=$(pa_api_get "$url" 2>/dev/null)
  [[ -n "$result" && "$result" != "null" ]]
}

# ── pa_clone_url ──────────────────────────────────────────────────────────────
pa_clone_url() {
  local org="$1" repo="$2"
  echo "${PA_CLONE_PREFIX}/${org}/${repo}.git"
}

# ── pa_push_url ───────────────────────────────────────────────────────────────
pa_push_url() {
  local org="$1" repo="$2"
  pa_clone_url "$org" "$repo"
}

# ── pa_create_repo ────────────────────────────────────────────────────────────
pa_create_repo() {
  local org="$1" repo="$2" description="${3:-Mirrored repository}"
  local token="${PLATFORM_TOKEN:-${GH_TOKEN:-${GITLAB_TOKEN:-}}}"

  # No-op if already exists
  if pa_repo_exists "$org" "$repo"; then
    _pa_info "  ${org}/${repo} already exists — skipping create"
    return 0
  fi

  _pa_info "  Creating ${org}/${repo} on ${PA_PLATFORM}"

  local payload http_code
  case "$PA_PLATFORM" in
    github)
      payload=$(python3 -c "import json; print(json.dumps({'name':'${repo}','description':'${description}','private':False,'auto_init':False}))")
      http_code=$(curl -sf -o /dev/null -w "%{http_code}" \
        -X POST \
        -H "$PA_AUTH_HEADER" \
        -H "Accept: application/vnd.github+json" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "${PA_API}/orgs/${org}/repos" 2>/dev/null || echo "0")
      ;;
    gitlab)
      local encoded_org
      encoded_org=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${org}',safe=''))")
      local ns_id
      ns_id=$(pa_api_get "${PA_API}/groups/${encoded_org}" 2>/dev/null | \
        python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
      [[ -z "$ns_id" ]] && { _pa_warn "Could not resolve GitLab namespace ID for ${org}"; return 1; }
      payload=$(python3 -c "import json; print(json.dumps({'name':'${repo}','path':'${repo}','namespace_id':${ns_id},'visibility':'public','description':'${description}','initialize_with_readme':False}))")
      http_code=$(curl -sf -o /dev/null -w "%{http_code}" \
        -X POST \
        -H "$PA_AUTH_HEADER" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "${PA_API}/projects" 2>/dev/null || echo "0")
      ;;
    gitea|forgejo|codeberg)
      payload=$(python3 -c "import json; print(json.dumps({'name':'${repo}','description':'${description}','private':False,'auto_init':False}))")
      http_code=$(curl -sf -o /dev/null -w "%{http_code}" \
        -X POST \
        -H "$PA_AUTH_HEADER" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "${PA_API}/orgs/${org}/repos" 2>/dev/null || echo "0")
      ;;
  esac

  if [[ "$http_code" =~ ^2 ]]; then
    _pa_info "  Created ${org}/${repo}"
    return 0
  else
    _pa_warn "  Failed to create ${org}/${repo} (HTTP ${http_code})"
    return 1
  fi
}

# ── pa_rate_limit_remaining ───────────────────────────────────────────────────
pa_rate_limit_remaining() {
  local remaining="unknown"
  case "$PA_PLATFORM" in
    github)
      remaining=$(pa_api_get "${PA_API}/rate_limit" 2>/dev/null | \
        python3 -c "import sys,json; print(json.load(sys.stdin)['resources']['core']['remaining'])" \
        2>/dev/null || echo "unknown")
      ;;
    gitlab)
      # GitLab exposes rate limit in response headers, not a dedicated endpoint.
      # Make a cheap call and read the header.
      curl -sf -o /dev/null -D "$_PA_HEADER_TMP" \
        -H "$PA_AUTH_HEADER" \
        "${PA_API}/version" 2>/dev/null || true
      remaining=$(grep -i "ratelimit-remaining:" "$_PA_HEADER_TMP" 2>/dev/null \
        | tr -d '\r' | awk '{print $2}' | head -1 || echo "unknown")
      ;;
    gitea|forgejo|codeberg)
      # Gitea/Forgejo: X-RateLimit-Remaining header on any response
      curl -sf -o /dev/null -D "$_PA_HEADER_TMP" \
        -H "$PA_AUTH_HEADER" \
        "${PA_API}/version" 2>/dev/null || true
      remaining=$(grep -i "x-ratelimit-remaining:" "$_PA_HEADER_TMP" 2>/dev/null \
        | tr -d '\r' | awk '{print $2}' | head -1 || echo "unknown")
      ;;
  esac
  echo "$remaining"
}
