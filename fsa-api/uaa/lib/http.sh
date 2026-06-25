#!/usr/bin/env bash
# lib/http.sh — HTTP response helpers for adapter scripts
#
# Adapter scripts write their response to stdout. These helpers format
# the output correctly for shell2http, webhook, and CGI backends.
#
# Usage:
#   source lib/http.sh
#   respond_json 200 '{"status":"ok"}'
#   respond_text 404 "not found"
#   respond_error 500 "adapter failed"

[[ -n "${_UAA_HTTP_LOADED:-}" ]] && return 0
_UAA_HTTP_LOADED=1

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/log.sh"

# UAA_BACKEND is set by server/start.sh; default to shell2http format
UAA_BACKEND="${UAA_BACKEND:-shell2http}"

# respond_json STATUS BODY
respond_json() {
  local status="${1:-200}" body="${2:-{}}"
  _emit_response "$status" "application/json" "$body"
}

# respond_text STATUS BODY
respond_text() {
  local status="${1:-200}" body="${2:-}"
  _emit_response "$status" "text/plain" "$body"
}

# respond_error STATUS MESSAGE
respond_error() {
  local status="${1:-500}" msg="${2:-internal error}"
  respond_json "$status" "{\"error\":$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$msg")}"
}

# respond_stream — write chunked lines (for streaming adapters)
respond_stream() {
  # shell2http supports streaming via -form flag; just write to stdout
  while IFS= read -r line; do
    echo "$line"
  done
}

_emit_response() {
  local status="$1" content_type="$2" body="$3"
  case "$UAA_BACKEND" in
    cgi)
      # CGI: emit HTTP headers then body
      printf 'Status: %s\r\nContent-Type: %s\r\n\r\n%s\n' \
        "$status" "$content_type" "$body"
      ;;
    shell2http|webhook|*)
      # shell2http/webhook: just emit body; status via exit code convention
      # shell2http supports X-Status header for non-200
      if [[ "$status" != "200" ]]; then
        printf 'X-Status: %s\n' "$status" >&2
      fi
      printf '%s\n' "$body"
      ;;
  esac
}

# auth_check — validate bearer token if UAA_AUTH is set
# Returns 0 if auth passes, exits 401 if it fails.
auth_check() {
  [[ -z "${UAA_AUTH:-}" ]] && return 0
  local provided="${HTTP_AUTHORIZATION:-${HTTP_X_API_KEY:-}}"
  provided="${provided#Bearer }"
  if [[ "$provided" != "$UAA_AUTH" ]]; then
    respond_error 401 "unauthorized"
    exit 0
  fi
}

# json_field KEY JSON — extract a field from a JSON string
json_field() {
  local key="$1" json="$2"
  echo "$json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('$key',''))" 2>/dev/null
}
