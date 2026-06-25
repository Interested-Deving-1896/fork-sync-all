#!/usr/bin/env bash
# fsa-api/core/lib/fsa-adapter.sh — FSA adapter lifecycle helpers
#
# Source this at the top of every FSA core adapter. Extends uaa/lib/adapter.sh
# with FSA-specific helpers: GitHub API access, workflow dispatch, quota checks.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/fsa-adapter.sh"

# Guard against double-sourcing
[[ -n "${_FSA_ADAPTER_LOADED:-}" ]] && return 0
_FSA_ADAPTER_LOADED=1

# Source UAA adapter base (pulls in log.sh, http.sh, shared.sh)
_FSA_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_FSA_ROOT="$(cd "${_FSA_CORE_DIR}/../.." && pwd)"
source "${_FSA_ROOT}/fsa-api/uaa/lib/adapter.sh" 2>/dev/null || true

# Source platform-adapter.sh for multi-platform support (GitHub, GitLab, Gitea, Forgejo, Codeberg)
# Provides: pa_init, pa_list_repos, pa_repo_exists, pa_api_get,
#           pa_clone_url, pa_push_url, pa_create_repo, pa_rate_limit_remaining
source "${_FSA_ROOT}/scripts/includes/platform-adapter.sh" 2>/dev/null || true

# ── Platform detection ────────────────────────────────────────────────────────
# FSA_PLATFORM — active platform for this adapter invocation.
# Defaults to 'github' (the source instance platform).
# Adapters that operate on a specific deployment set FSA_PLATFORM before sourcing,
# or call fsa_platform_init explicitly.
FSA_PLATFORM="${FSA_PLATFORM:-github}"
FSA_PLATFORM_HOST="${FSA_PLATFORM_HOST:-}"
FSA_PLATFORM_TOKEN="${FSA_PLATFORM_TOKEN:-}"

# fsa_platform_init [PLATFORM] [HOST]
# Initialises platform-adapter.sh for the given platform.
# Selects the correct token secret per platform automatically.
fsa_platform_init() {
  local platform="${1:-${FSA_PLATFORM:-github}}"
  local host="${2:-${FSA_PLATFORM_HOST:-}}"
  local token
  case "$platform" in
    github)   token="${GH_TOKEN:-${SYNC_TOKEN:-}}" ;;
    gitlab)   token="${GITLAB_TOKEN:-${FSA_PLATFORM_TOKEN:-}}" ;;
    gitea)    token="${GITEA_TOKEN:-${FSA_PLATFORM_TOKEN:-}}" ;;
    forgejo)  token="${FORGEJO_TOKEN:-${FSA_PLATFORM_TOKEN:-}}" ;;
    codeberg) token="${CODEBERG_TOKEN:-${FSA_PLATFORM_TOKEN:-}}" ;;
    *)        token="${FSA_PLATFORM_TOKEN:-${GH_TOKEN:-}}" ;;
  esac
  PLATFORM_TOKEN="$token" pa_init "$platform" "$host" 2>/dev/null || true
}

# Auto-init for the default platform so existing adapters work unchanged
fsa_platform_init "${FSA_PLATFORM:-github}" "${FSA_PLATFORM_HOST:-}" 2>/dev/null || true

# ── Token ─────────────────────────────────────────────────────────────────────
GH_TOKEN="${GH_TOKEN:-${SYNC_TOKEN:-}}"
FSA_REPO="${FSA_REPO:-${GITHUB_REPOSITORY:-Interested-Deving-1896/fork-sync-all}}"
FSA_ORG="${FSA_ORG:-${FSA_REPO%%/*}}"
GH_API="${GH_API:-https://api.github.com}"

# Point shared.sh toggle system at FSA's toggles file
FSA_TOGGLES_FILE="${_FSA_ROOT}/fsa-api/config/fsa-toggles.yml"
UAA_TOGGLES_FILE="$FSA_TOGGLES_FILE"

# Override shared.sh quota_fetch() — uses pa_rate_limit_remaining when platform-adapter
# is initialised, falls back to direct GitHub API call for backward compatibility.
quota_fetch() {
  if [[ -n "${PA_PLATFORM:-}" ]]; then
    pa_rate_limit_remaining 2>/dev/null || echo 9999
  else
    curl -sf \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      "${GH_API}/rate_limit" \
      | python3 -c "import json,sys; print(json.load(sys.stdin).get('resources',{}).get('core',{}).get('remaining',0))" \
      2>/dev/null || echo 0
  fi
}

# ── GitHub API helpers ────────────────────────────────────────────────────────
fsa_api_get() {
  local path="$1"
  curl -sf \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${GH_API}${path}" 2>/dev/null || echo "{}"
}

fsa_api_post() {
  local path="$1" data="${2:-{}}"
  curl -sf -X POST \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    -d "$data" \
    "${GH_API}${path}" 2>/dev/null || echo "{}"
}

fsa_api_patch() {
  local path="$1" data="${2:-{}}"
  curl -sf -X PATCH \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    -d "$data" \
    "${GH_API}${path}" 2>/dev/null || echo "{}"
}

fsa_api_delete() {
  local path="$1"
  curl -sf -X DELETE \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${GH_API}${path}" 2>/dev/null
}

# ── GraphQL ───────────────────────────────────────────────────────────────────
fsa_graphql() {
  local query="$1"
  curl -sf -X POST \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"query\": $(echo "$query" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))" 2>/dev/null)}" \
    "${GH_API}/graphql" 2>/dev/null || echo "{}"
}

# ── Quota check — delegates to shared.sh quota_check() ───────────────────────
# quota_fetch() is overridden above with the GitHub-specific implementation.
# fsa_quota_remaining / fsa_quota_check are kept as aliases for adapters that
# use the fsa_ prefix; they delegate to shared.sh's generic implementations.

fsa_quota_remaining() {
  quota_fetch
}

fsa_quota_check() {
  quota_check "${1:-200}"
}

# ── JSON response helpers — aliases to shared.sh ──────────────────────────────
# shared.sh provides json_ok / json_error / json_list.
# fsa_ prefixed aliases are kept for backward compatibility with existing adapters.
fsa_ok()    { json_ok    "$@"; }
fsa_error() { json_error "$@"; }
fsa_list()  { json_list  "$@"; }

# ── Toggle helpers — delegates to shared.sh toggle_* ─────────────────────────
# UAA_TOGGLES_FILE is set above to FSA_TOGGLES_FILE.
# fsa_toggle_* aliases kept for backward compatibility.
fsa_toggle_get()     { toggle_get     "$@"; }
fsa_toggle_enabled() { toggle_enabled "$@"; }
