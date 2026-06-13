#!/usr/bin/env bash
# lib/adapter.sh — adapter lifecycle helpers
#
# Source this at the top of every adapter script. Provides:
#   - Standard env setup (REPO_ROOT, adapter name)
#   - Input parsing (query params, request body, path vars)
#   - Capability declaration (adapter_provides)
#   - Health check support

[[ -n "${_UAA_ADAPTER_LOADED:-}" ]] && return 0
_UAA_ADAPTER_LOADED=1

ADAPTER_SCRIPT="${BASH_SOURCE[1]:-$0}"
ADAPTER_DIR="$(cd "$(dirname "$ADAPTER_SCRIPT")" && pwd)"
ADAPTER_NAME="$(basename "$ADAPTER_DIR")"
REPO_ROOT="${REPO_ROOT:-$(cd "$ADAPTER_DIR/../.." && pwd)}"

source "$REPO_ROOT/lib/log.sh"
source "$REPO_ROOT/lib/http.sh"

# ── Input helpers ─────────────────────────────────────────────────────────────

# query_param KEY [DEFAULT]
# Reads from shell2http's $v_KEY env var (set automatically by shell2http
# from ?key=value query params), falling back to DEFAULT.
query_param() {
  local key="$1" default="${2:-}"
  local var="v_${key}"
  echo "${!var:-$default}"
}

# request_body — read the full request body from stdin
request_body() {
  cat -
}

# path_var INDEX — extract a path segment from $REQUEST_URI
# e.g. for /filesystem/ls/tmp, path_var 2 → "ls"
path_var() {
  local idx="$1"
  echo "${REQUEST_URI:-}" | tr '/' '\n' | sed -n "$((idx+1))p"
}

# require_param KEY — exit 400 if query param is empty
require_param() {
  local key="$1"
  local val
  val="$(query_param "$key")"
  if [[ -z "$val" ]]; then
    respond_error 400 "missing required parameter: $key"
    exit 0
  fi
  echo "$val"
}

# ── Capability declaration ────────────────────────────────────────────────────

# adapter_provides — print adapter metadata as JSON (used by /api/adapters endpoint)
adapter_provides() {
  local name="${1:-$ADAPTER_NAME}"
  local description="${2:-}"
  local version="${3:-0.1.0}"
  cat << EOF
{
  "adapter": "$name",
  "description": "$description",
  "version": "$version",
  "script": "$ADAPTER_SCRIPT"
}
EOF
}

# ── Health check ──────────────────────────────────────────────────────────────

# adapter_health OK|FAIL [MESSAGE]
adapter_health() {
  local status="${1:-OK}" msg="${2:-}"
  local ok="true"
  [[ "$status" != "OK" ]] && ok="false"
  respond_json 200 "{\"healthy\":$ok,\"adapter\":\"$ADAPTER_NAME\",\"message\":$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$msg")}"
}
