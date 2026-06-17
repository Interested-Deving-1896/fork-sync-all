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
#   FLUSH_ACTIVE_TTL_HOURS — hours before FLUSH_ACTIVE is considered stale (default: 8)

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

# ── Set FLUSH_ACTIVE=true ─────────────────────────────────────────────────────
pipeline_guard_start() {
  local label="${1:-${PIPELINE_LABEL:-pipeline}}"
  _pg_info "Starting protected pipeline: ${label}"

  if curl -sf -X PUT \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "Content-Type: application/json" \
      "${_GH_API}/repos/${REPO}/actions/variables/FLUSH_ACTIVE" \
      -d '{"name":"FLUSH_ACTIVE","value":"true"}' > /dev/null 2>&1; then
    _pg_info "FLUSH_ACTIVE=true set (updated)"
  else
    curl -sf -X POST \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "Content-Type: application/json" \
      "${_GH_API}/repos/${REPO}/actions/variables" \
      -d '{"name":"FLUSH_ACTIVE","value":"true"}' > /dev/null 2>&1 || true
    _pg_info "FLUSH_ACTIVE=true set (created)"
  fi

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
  _pg_info "Ending protected pipeline: ${label}"

  curl -sf -X PUT \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Content-Type: application/json" \
    "${_GH_API}/repos/${REPO}/actions/variables/FLUSH_ACTIVE" \
    -d '{"name":"FLUSH_ACTIVE","value":"false"}' > /dev/null 2>&1 || true

  _pg_info "FLUSH_ACTIVE=false cleared"
  echo "pipeline_guard_end=true" >> "${GITHUB_OUTPUT:-/dev/null}"
}
