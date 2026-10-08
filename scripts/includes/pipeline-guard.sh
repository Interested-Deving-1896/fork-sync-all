#!/usr/bin/env bash
#
# scripts/includes/pipeline-guard.sh — quota + runner reservation for
# protected pipelines (flush lifecycle, critical deploy).
#
# Provides three functions:
#
#   pipeline_guard_start [label]
#     Sets FLUSH_ACTIVE=true, logs quota headroom.
#     Call at the start of any protected pipeline job.
#
#   pipeline_guard_checkpoint [min_quota] [label]
#     Checks remaining quota. If below min_quota, sleeps until reset
#     (up to MAX_PAUSE_SECONDS). Exits 1 if wait exceeds the limit.
#     Call between stages of a multi-stage pipeline.
#
#   pipeline_guard_end [label]
#     Clears FLUSH_ACTIVE=false. Call in an always() step.
#
# Required env vars:
#   GH_TOKEN          — PAT with actions:write scope
#   REPO              — owner/repo (set automatically in Actions as github.repository)
#
# Optional env vars:
#   PIPELINE_LABEL        — human-readable name for log messages (default: pipeline)
#   MAX_PAUSE_SECONDS     — max seconds to wait for quota reset (default: 3900 = 65 min)
#   PAUSE_POLL_SECONDS    — polling interval while paused (default: 120)
#   FLUSH_ACTIVE_TTL_HOURS — lease lifetime in hours (default: 8)
#   PIPELINE_LEASE_OWNER   — explicit lease identity. Defaults to
#                            "${GITHUB_WORKFLOW}:${GITHUB_RUN_ID}:${GITHUB_RUN_ATTEMPT}".

# Guard against double-sourcing
[[ -n "${_PIPELINE_GUARD_LOADED:-}" ]] && return 0
_PIPELINE_GUARD_LOADED=1

GH_TOKEN="${GH_TOKEN:-}"
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
MAX_PAUSE_SECONDS="${MAX_PAUSE_SECONDS:-3900}"
PAUSE_POLL_SECONDS="${PAUSE_POLL_SECONDS:-120}"
_GH_API="${_GH_API:-https://api.github.com}"  # overridable for testing

_pg_info() { echo "[pipeline-guard${PIPELINE_LABEL:+ (${PIPELINE_LABEL})}] $*" >&2; }
_pg_warn() { echo "[pipeline-guard:warn] $*" >&2; }

_pg_lease_owner() {
  local label="$1"
  printf '%s' "${PIPELINE_LEASE_OWNER:-${GITHUB_WORKFLOW:-${label}}:${GITHUB_RUN_ID:-local}:${GITHUB_RUN_ATTEMPT:-1}}"
}

# Print "HTTP status<TAB>body". Callers deliberately distinguish an absent
# variable (404) from an API outage: a failed read must never be treated as an
# unlocked mutex.
_pg_get_lease() {
  local response status body
  response=$(curl -sS -w $'\n%{http_code}' \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${_GH_API}/repos/${REPO}/actions/variables/FLUSH_ACTIVE" 2>/dev/null) || return 1
  status=$(printf '%s\n' "$response" | tail -1)
  body=$(printf '%s\n' "$response" | sed '$d')
  # GitHub REST responses may be pretty-printed across multiple lines. Compact
  # JSON before joining it to the status so the caller's tab-delimited read
  # cannot truncate the lease body at its first newline.
  if [[ -n "$body" ]]; then
    body=$(printf '%s' "$body" | python3 -c \
      "import json,sys; print(json.dumps(json.load(sys.stdin),separators=(',',':')))" \
      2>/dev/null) || return 1
  fi
  printf '%s\t%s\n' "$status" "$body"
}

_pg_write_lease() {
  local method="$1" endpoint="$2" value="$3" response status body
  body=$(python3 -c "import json,sys; print(json.dumps({'name':'FLUSH_ACTIVE','value':sys.argv[1]},separators=(',',':')))" "$value") || return 1
  response=$(curl -sS -w $'\n%{http_code}' -X "$method" \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    "${_GH_API}/repos/${REPO}/actions/variables${endpoint}" \
    -d "$body" 2>/dev/null) || return 1
  status=$(printf '%s\n' "$response" | tail -1)
  [[ "$status" == "201" || "$status" == "204" ]]
}

_pg_parse_lease() {
  python3 -c "
import json,sys,time
raw=sys.argv[1]
updated=sys.argv[2]
ttl=int(sys.argv[3]) * 3600
def updated_expiry():
    try:
        from datetime import datetime
        stamp=int(datetime.fromisoformat(updated.replace('Z','+00:00')).timestamp())
    except Exception:
        stamp=int(time.time())
    return stamp + ttl
if raw == 'false' or not raw:
    print('false', '', '0', sep='\t')
    raise SystemExit
if raw == 'true':
    # Legacy Boolean leases have no owner. Honour them until their server-side
    # update time expires so an upgrade cannot steal a live pipeline's lock.
    print('true', 'legacy', updated_expiry(), sep='\t')
    raise SystemExit
try:
    lease=json.loads(raw)
except Exception:
    # Fail closed during the TTL, but allow recovery from permanently corrupt
    # state once the server-side update timestamp proves it is stale.
    print('true', 'invalid', updated_expiry(), sep='\t')
    raise SystemExit
print(str(bool(lease.get('active'))).lower(), lease.get('owner',''), int(lease.get('expires_at',0) or 0), sep='\t')
" "$1" "$2" "${FLUSH_ACTIVE_TTL_HOURS:-8}"
}

# ── Set FLUSH_ACTIVE=true ─────────────────────────────────────────────────────
pipeline_guard_start() {
  local label="${1:-${PIPELINE_LABEL:-pipeline}}"
  local owner lease_record http body current_value updated_at active current_owner expires_at now payload verify_record verify_body verify_value verify_owner verify_active
  _pg_info "Starting protected pipeline: ${label}"

  [[ -n "$GH_TOKEN" && -n "$REPO" ]] || { _pg_warn "GH_TOKEN and REPO are required"; return 1; }
  owner=$(_pg_lease_owner "$label")
  lease_record=$(_pg_get_lease) || { _pg_warn "Cannot read FLUSH_ACTIVE; refusing to acquire lease"; return 1; }
  IFS=$'\t' read -r http body <<< "$lease_record"
  if [[ "$http" == "200" ]]; then
    current_value=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('value','false'))" "$body") || {
      _pg_warn "Malformed FLUSH_ACTIVE response; refusing to acquire lease"; return 1;
    }
    updated_at=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('updated_at',''))" "$body") || return 1
    IFS=$'\t' read -r active current_owner expires_at < <(_pg_parse_lease "$current_value" "$updated_at")
    now=$(date +%s)
    if [[ "$active" == "true" && "$current_owner" != "$owner" && "$expires_at" -gt "$now" ]]; then
      _pg_warn "FLUSH_ACTIVE is owned by ${current_owner} until ${expires_at}; refusing to steal lease"
      return 1
    fi
  elif [[ "$http" != "404" ]]; then
    _pg_warn "FLUSH_ACTIVE read returned HTTP ${http}; refusing to acquire lease"
    return 1
  fi

  now=$(date +%s)
  payload=$(python3 -c "import json,sys; print(json.dumps({'active':True,'owner':sys.argv[1],'workflow':sys.argv[2],'run_id':sys.argv[3],'run_attempt':int(sys.argv[4]),'acquired_at':int(sys.argv[5]),'expires_at':int(sys.argv[6])},separators=(',',':')))" \
    "$owner" "${GITHUB_WORKFLOW:-$label}" "${GITHUB_RUN_ID:-local}" "${GITHUB_RUN_ATTEMPT:-1}" "$now" "$(( now + ${FLUSH_ACTIVE_TTL_HOURS:-8} * 3600 ))") || return 1
  if [[ "$http" == "404" ]]; then
    _pg_write_lease POST "" "$payload" || { _pg_warn "Failed to create FLUSH_ACTIVE lease"; return 1; }
  else
    _pg_write_lease PATCH "/FLUSH_ACTIVE" "$payload" || { _pg_warn "Failed to update FLUSH_ACTIVE lease"; return 1; }
  fi

  # Verify ownership after the write. This catches both API failures and the
  # loser of a concurrent acquire race.
  verify_record=$(_pg_get_lease) || { _pg_warn "Cannot verify FLUSH_ACTIVE lease"; return 1; }
  IFS=$'\t' read -r http verify_body <<< "$verify_record"
  [[ "$http" == "200" ]] || { _pg_warn "FLUSH_ACTIVE verification returned HTTP ${http}"; return 1; }
  verify_value=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('value',''))" "$verify_body") || return 1
  IFS=$'\t' read -r verify_active verify_owner _ < <(_pg_parse_lease "$verify_value" "")
  [[ "$verify_active" == "true" && "$verify_owner" == "$owner" ]] || {
    _pg_warn "FLUSH_ACTIVE ownership verification failed; lease belongs to ${verify_owner:-unknown}"
    return 1
  }
  _pg_info "FLUSH_ACTIVE lease acquired by ${owner}"
  echo "pipeline_guard_owner=${owner}" >> "${GITHUB_OUTPUT:-/dev/null}"

  # Log current quota headroom
  local remaining
  remaining=$(curl -sf \
    -H "Authorization: token ${GH_TOKEN}" \
    "${_GH_API}/rate_limit" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['resources']['core']['remaining'])" \
    2>/dev/null || echo "unknown")
  _pg_info "Quota at start: ${remaining} remaining"
  echo "pipeline_guard_start_quota=${remaining}" >> "${GITHUB_OUTPUT:-/dev/null}"
}

# ── Quota checkpoint with pause/resume ───────────────────────────────────────
pipeline_guard_checkpoint() {
  local min_quota="${1:-600}"
  local label="${2:-checkpoint}"

  local remaining reset_at
  remaining=$(curl -sf \
    -H "Authorization: token ${GH_TOKEN}" \
    "${_GH_API}/rate_limit" \
    | python3 -c "import json,sys; d=json.load(sys.stdin)['resources']['core']; print(d['remaining'])" \
    2>/dev/null || echo "0")
  reset_at=$(curl -sf \
    -H "Authorization: token ${GH_TOKEN}" \
    "${_GH_API}/rate_limit" \
    | python3 -c "import json,sys; d=json.load(sys.stdin)['resources']['core']; print(d['reset'])" \
    2>/dev/null || echo "0")

  _pg_info "Quota checkpoint [${label}]: ${remaining} remaining (need ${min_quota})"

  if [[ "${remaining}" -ge "${min_quota}" ]]; then
    echo "pipeline_guard_paused=false" >> "${GITHUB_OUTPUT:-/dev/null}"
    return 0
  fi

  # Quota too low — pause until reset
  local now wait_seconds
  now=$(date +%s)
  wait_seconds=$(( reset_at - now + 30 ))

  if [[ ${wait_seconds} -le 0 ]]; then
    _pg_info "Reset already passed — continuing immediately"
    echo "pipeline_guard_paused=false" >> "${GITHUB_OUTPUT:-/dev/null}"
    return 0
  fi

  if [[ ${wait_seconds} -gt ${MAX_PAUSE_SECONDS} ]]; then
    _pg_warn "Wait time ${wait_seconds}s exceeds MAX_PAUSE_SECONDS ${MAX_PAUSE_SECONDS}s — aborting"
    echo "pipeline_guard_paused=true" >> "${GITHUB_OUTPUT:-/dev/null}"
    return 1
  fi

  local reset_human
  reset_human=$(python3 -c "from datetime import datetime,timezone; print(datetime.fromtimestamp(${reset_at}, tz=timezone.utc).strftime('%H:%M:%S UTC'))" 2>/dev/null || echo "${reset_at}")
  _pg_info "Quota low (${remaining} < ${min_quota}) — pausing ${wait_seconds}s until reset at ${reset_human}"
  echo "pipeline_guard_paused=true" >> "${GITHUB_OUTPUT:-/dev/null}"

  local elapsed=0
  while [[ ${elapsed} -lt ${wait_seconds} ]]; do
    sleep "${PAUSE_POLL_SECONDS}"
    elapsed=$(( elapsed + PAUSE_POLL_SECONDS ))
    remaining=$(curl -sf \
      -H "Authorization: token ${GH_TOKEN}" \
      "${_GH_API}/rate_limit" \
      | python3 -c "import json,sys; print(json.load(sys.stdin)['resources']['core']['remaining'])" \
      2>/dev/null || echo "0")
    _pg_info "  [${elapsed}s/${wait_seconds}s] Quota: ${remaining}"
    if [[ "${remaining}" -ge "${min_quota}" ]]; then
      _pg_info "Quota restored (${remaining}) — resuming"
      echo "pipeline_guard_paused=false" >> "${GITHUB_OUTPUT:-/dev/null}"
      return 0
    fi
  done

  _pg_info "Pause complete — continuing (quota may still be low)"
  echo "pipeline_guard_paused=false" >> "${GITHUB_OUTPUT:-/dev/null}"
}

# ── Clear FLUSH_ACTIVE=false ──────────────────────────────────────────────────
pipeline_guard_end() {
  local label="${1:-${PIPELINE_LABEL:-pipeline}}"
  local owner lease_record http body current_value updated_at active current_owner expires_at verify_record verify_body verify_value
  _pg_info "Ending protected pipeline: ${label}"

  [[ -n "$GH_TOKEN" && -n "$REPO" ]] || { _pg_warn "GH_TOKEN and REPO are required"; return 1; }
  owner=$(_pg_lease_owner "$label")
  lease_record=$(_pg_get_lease) || { _pg_warn "Cannot read FLUSH_ACTIVE; refusing unverified clear"; return 1; }
  IFS=$'\t' read -r http body <<< "$lease_record"
  if [[ "$http" == "404" ]]; then
    _pg_info "FLUSH_ACTIVE is absent; nothing to clear"
    echo "pipeline_guard_end=true" >> "${GITHUB_OUTPUT:-/dev/null}"
    return 0
  fi
  [[ "$http" == "200" ]] || { _pg_warn "FLUSH_ACTIVE read returned HTTP ${http}; refusing unverified clear"; return 1; }
  current_value=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('value','false'))" "$body") || return 1
  updated_at=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('updated_at',''))" "$body") || return 1
  IFS=$'\t' read -r active current_owner expires_at < <(_pg_parse_lease "$current_value" "$updated_at")
  if [[ "$active" != "true" ]]; then
    _pg_info "FLUSH_ACTIVE is already inactive"
    echo "pipeline_guard_end=true" >> "${GITHUB_OUTPUT:-/dev/null}"
    return 0
  fi
  if [[ "$current_owner" != "$owner" ]]; then
    _pg_info "Lease belongs to ${current_owner}; ${owner} will not clear it"
    echo "pipeline_guard_end=false" >> "${GITHUB_OUTPUT:-/dev/null}"
    return 0
  fi

  # Keep the releasing owner in the inactive tombstone. The GitHub variables
  # API has no conditional update primitive, so workflow-level concurrency is
  # the primary serialization mechanism. This owner-bearing value plus the
  # read-after-write check makes any lost race visible and fails closed.
  local released_at inactive_payload verify_active verify_owner
  released_at=$(date +%s)
  inactive_payload=$(python3 -c "import json,sys; print(json.dumps({'active':False,'owner':sys.argv[1],'released_at':int(sys.argv[2])},separators=(',',':')))" \
    "$owner" "$released_at") || return 1
  _pg_write_lease PATCH "/FLUSH_ACTIVE" "$inactive_payload" || { _pg_warn "Failed to clear FLUSH_ACTIVE lease"; return 1; }
  verify_record=$(_pg_get_lease) || { _pg_warn "Cannot verify FLUSH_ACTIVE clear"; return 1; }
  IFS=$'\t' read -r http verify_body <<< "$verify_record"
  [[ "$http" == "200" ]] || { _pg_warn "FLUSH_ACTIVE clear verification returned HTTP ${http}"; return 1; }
  verify_value=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('value',''))" "$verify_body") || return 1
  IFS=$'\t' read -r verify_active verify_owner _ < <(_pg_parse_lease "$verify_value" "")
  [[ "$verify_active" == "false" && "$verify_owner" == "$owner" ]] || {
    _pg_warn "FLUSH_ACTIVE clear verification failed; current owner is ${verify_owner:-unknown}"
    return 1
  }
  _pg_info "FLUSH_ACTIVE lease released by ${owner}"
  echo "pipeline_guard_end=true" >> "${GITHUB_OUTPUT:-/dev/null}"
}
