#!/usr/bin/env bash
# scripts/includes/bugzilla-api.sh — Bugzilla REST API helper
#
# Source this file from any script that needs to call a Bugzilla instance:
#
#   source "$(dirname "${BASH_SOURCE[0]}")/includes/bugzilla-api.sh"
#
# Provides:
#   bz_get    ENDPOINT [CURL_ARGS...]   — authenticated GET
#   bz_post   ENDPOINT JSON_BODY        — authenticated POST
#   bz_put    ENDPOINT JSON_BODY        — authenticated PUT
#   bz_file_bug   PRODUCT COMPONENT SUMMARY DESCRIPTION [SEVERITY] [PRIORITY]
#                 — create a new bug; prints bug ID on stdout
#   bz_update_bug BUG_ID JSON_FIELDS    — update fields on an existing bug
#   bz_add_comment BUG_ID COMMENT       — append a comment to a bug
#   bz_search PARAMS                    — search bugs; prints JSON array
#   bz_get_bug BUG_ID                   — fetch a single bug; prints JSON
#   bz_resolve_bug BUG_ID RESOLUTION [COMMENT]
#                 — set status=RESOLVED with given resolution (FIXED, WONTFIX, etc.)
#   bz_is_configured                    — returns 0 if BZ_URL and BZ_API_KEY are set
#
# Required env vars (set before sourcing, or loaded from config):
#   BZ_URL      — base URL of the Bugzilla instance (e.g. https://bugzilla.example.com)
#   BZ_API_KEY  — Bugzilla API key (User Preferences → API Keys)
#
# Optional env vars:
#   BZ_DRY_RUN  — if "true", log actions but do not make write calls
#
# All status/log messages go to stderr. Stdout is reserved for return values.
#
# Rate-limit behaviour:
#   HTTP 429: reads Retry-After header, sleeps, retries (max 3 attempts)
#   HTTP 5xx: retries with 10s backoff (max 3 attempts)
#   Other errors: prints body to stderr, returns 1

[[ -n "${_BZ_API_LOADED:-}" ]] && return 0
_BZ_API_LOADED=1

_bz_info() { echo "[bugzilla-api] $*" >&2; }
_bz_warn() { echo "[bugzilla-api][warn] $*" >&2; }
_bz_dry()  { echo "[bugzilla-api][dry-run] $*" >&2; }

# ── bz_is_configured ─────────────────────────────────────────────────────────
bz_is_configured() {
  [[ -n "${BZ_URL:-}" && -n "${BZ_API_KEY:-}" ]]
}

# ── _bz_api (internal) ───────────────────────────────────────────────────────
# Usage: _bz_api METHOD ENDPOINT [CURL_ARGS...]
# Prints response body to stdout. Returns 0 on 2xx, 1 on error.
_bz_api() {
  local method="$1" endpoint="$2"
  shift 2

  local url="${BZ_URL%/}/rest/${endpoint#/}"
  local max_retries=3
  local attempt=0
  local _hdr_tmp
  _hdr_tmp=$(mktemp)

  while [[ $attempt -lt $max_retries ]]; do
    (( attempt++ )) || true
    local _body_tmp
    _body_tmp=$(mktemp)

    local http_code
    http_code=$(curl -s -w "%{http_code}" -o "$_body_tmp" -D "$_hdr_tmp" \
      -X "$method" \
      -H "X-BUGZILLA-API-KEY: ${BZ_API_KEY}" \
      -H "Content-Type: application/json" \
      -H "Accept: application/json" \
      "$url" "$@" 2>/dev/null)
    http_code="${http_code:-000}"

    local body
    body=$(cat "$_body_tmp" 2>/dev/null || echo "")
    rm -f "$_body_tmp"

    if [[ "$http_code" =~ ^2 ]]; then
      rm -f "$_hdr_tmp"
      echo "$body"
      return 0
    fi

    local err_msg
    err_msg=$(echo "$body" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(d.get('message') or d.get('error') or str(d)[:200])
except Exception:
    print(sys.stdin.read()[:200])
" 2>/dev/null || echo "$body" | head -c 200)

    if [[ "$http_code" == "429" ]]; then
      local retry_after
      retry_after=$(grep -i "retry-after:" "$_hdr_tmp" 2>/dev/null \
        | tr -d '\r' | awk '{print $2}' || echo "60")
      _bz_warn "Rate limited (attempt ${attempt}) — sleeping ${retry_after}s"
      sleep "${retry_after:-60}"
    elif [[ "$http_code" =~ ^5 ]]; then
      _bz_warn "Server error ${http_code} (attempt ${attempt}) — retrying in 10s: ${err_msg}"
      sleep 10
    else
      _bz_warn "API error ${http_code}: ${err_msg}"
      rm -f "$_hdr_tmp"
      return 1
    fi
  done

  rm -f "$_hdr_tmp"
  _bz_warn "Failed after ${max_retries} attempts"
  return 1
}

# ── bz_get ───────────────────────────────────────────────────────────────────
bz_get() {
  local endpoint="$1"; shift
  _bz_api GET "$endpoint" "$@"
}

# ── bz_post ──────────────────────────────────────────────────────────────────
bz_post() {
  local endpoint="$1" body="$2"
  if [[ "${BZ_DRY_RUN:-false}" == "true" ]]; then
    _bz_dry "POST ${endpoint}: ${body}"
    echo '{"id":0}'
    return 0
  fi
  _bz_api POST "$endpoint" -d "$body"
}

# ── bz_put ───────────────────────────────────────────────────────────────────
bz_put() {
  local endpoint="$1" body="$2"
  if [[ "${BZ_DRY_RUN:-false}" == "true" ]]; then
    _bz_dry "PUT ${endpoint}: ${body}"
    return 0
  fi
  _bz_api PUT "$endpoint" -d "$body"
}

# ── bz_get_bug ───────────────────────────────────────────────────────────────
bz_get_bug() {
  local bug_id="$1"
  bz_get "bug/${bug_id}"
}

# ── bz_search ────────────────────────────────────────────────────────────────
# PARAMS is a URL query string, e.g. "product=MyProduct&summary=foo&status=NEW"
bz_search() {
  local params="$1"
  bz_get "bug?${params}"
}

# ── bz_file_bug ──────────────────────────────────────────────────────────────
# Prints the new bug ID on stdout.
bz_file_bug() {
  local product="$1"
  local component="$2"
  local summary="$3"
  local description="$4"
  local severity="${5:-normal}"
  local priority="${6:-P3}"

  local body
  body=$(python3 -c "
import json, sys
print(json.dumps({
  'product':     sys.argv[1],
  'component':   sys.argv[2],
  'summary':     sys.argv[3],
  'description': sys.argv[4],
  'severity':    sys.argv[5],
  'priority':    sys.argv[6],
  'version':     'unspecified',
  'type':        'defect',
}, separators=(',',':')))
" "$product" "$component" "$summary" "$description" "$severity" "$priority")

  _bz_info "Filing bug: [${product}/${component}] ${summary}"
  local result
  result=$(bz_post "bug" "$body") || return 1

  local bug_id
  bug_id=$(echo "$result" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d.get('id',''))
" 2>/dev/null)

  if [[ -z "$bug_id" || "$bug_id" == "0" ]]; then
    _bz_warn "Bug filed but could not parse ID from response: ${result}"
    return 1
  fi

  _bz_info "Filed bug ${bug_id}: ${summary}"
  echo "$bug_id"
}

# ── bz_update_bug ────────────────────────────────────────────────────────────
# JSON_FIELDS is a JSON object of fields to update, e.g. '{"status":"ASSIGNED"}'
bz_update_bug() {
  local bug_id="$1" fields="$2"
  _bz_info "Updating bug ${bug_id}: ${fields}"
  bz_put "bug/${bug_id}" "$fields" > /dev/null
}

# ── bz_add_comment ───────────────────────────────────────────────────────────
bz_add_comment() {
  local bug_id="$1" comment="$2"
  local body
  body=$(python3 -c "
import json,sys
print(json.dumps({'comment': sys.argv[1]}, separators=(',',':')))
" "$comment")
  _bz_info "Adding comment to bug ${bug_id}"
  bz_post "bug/${bug_id}/comment" "$body" > /dev/null
}

# ── bz_resolve_bug ───────────────────────────────────────────────────────────
bz_resolve_bug() {
  local bug_id="$1"
  local resolution="${2:-FIXED}"   # FIXED | WONTFIX | DUPLICATE | WORKSFORME | INVALID
  local comment="${3:-}"

  local fields
  fields=$(python3 -c "
import json,sys
d={'status':'RESOLVED','resolution':sys.argv[1]}
if sys.argv[2]:
    d['comment']={'body':sys.argv[2]}
print(json.dumps(d, separators=(',',':')))
" "$resolution" "$comment")

  _bz_info "Resolving bug ${bug_id} as ${resolution}"
  bz_put "bug/${bug_id}" "$fields" > /dev/null
}
