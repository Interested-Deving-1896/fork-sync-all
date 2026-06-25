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

# Source UAA adapter base
_FSA_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_FSA_ROOT="$(cd "${_FSA_CORE_DIR}/../.." && pwd)"
source "${_FSA_ROOT}/fsa-api/uaa/lib/adapter.sh" 2>/dev/null || true

# ── Token ─────────────────────────────────────────────────────────────────────
GH_TOKEN="${GH_TOKEN:-${SYNC_TOKEN:-}}"
FSA_REPO="${FSA_REPO:-${GITHUB_REPOSITORY:-Interested-Deving-1896/fork-sync-all}}"
FSA_ORG="${FSA_ORG:-${FSA_REPO%%/*}}"
GH_API="${GH_API:-https://api.github.com}"

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

# ── Quota check ───────────────────────────────────────────────────────────────
fsa_quota_remaining() {
  fsa_api_get "/rate_limit" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('resources',{}).get('core',{}).get('remaining',0))" 2>/dev/null || echo 0
}

fsa_quota_check() {
  local min="${1:-200}"
  local remaining
  remaining=$(fsa_quota_remaining)
  if [[ "$remaining" -lt "$min" ]]; then
    fsa_error "Quota too low: ${remaining} remaining (need ${min})" 429
    return 1
  fi
  return 0
}

# ── JSON response helpers ─────────────────────────────────────────────────────
fsa_ok()    { echo "{\"ok\":true,\"data\":${1:-null}}"; }
fsa_error() { echo "{\"ok\":false,\"error\":\"${1:-error}\",\"code\":${2:-500}}"; }
fsa_list()  { echo "{\"ok\":true,\"count\":$(echo "$1" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0),\"items\":${1:-[]}}"; }

# ── Toggle helpers ────────────────────────────────────────────────────────────
FSA_TOGGLES_FILE="${_FSA_ROOT}/fsa-api/config/fsa-toggles.yml"

fsa_toggle_get() {
  local name="$1"
  python3 -c "
import yaml, sys
with open('${FSA_TOGGLES_FILE}') as f:
    cfg = yaml.safe_load(f)
toggles = cfg.get('toggles', {})
t = toggles.get('${name}')
if t is None:
    print('unknown')
else:
    print('enabled' if t.get('enabled', True) else 'disabled')
" 2>/dev/null || echo "unknown"
}

fsa_toggle_enabled() {
  local name="$1"
  [[ "$(fsa_toggle_get "$name")" == "enabled" ]]
}
