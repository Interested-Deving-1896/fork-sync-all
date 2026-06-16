#!/usr/bin/env bash
# scripts/includes/quota-snapshot.sh — lightweight quota pre-flight + snapshot
#
# Replaces the duplicated inline quota pre-flight block that appears in ~47
# workflows. Provides a single function that:
#
#   1. Reads current GitHub REST core quota (1 API call)
#   2. Writes remaining/reset/skip to GITHUB_OUTPUT (for step conditionals)
#   3. Optionally writes a compact snapshot to a repo Actions variable
#      (QUOTA_SNAPSHOT) so downstream workflows can read it without an API call
#   4. Optionally writes a quota status line to GITHUB_STEP_SUMMARY
#
# Usage in a workflow step:
#
#   - name: Quota pre-flight
#     id: quota
#     env:
#       GH_TOKEN: ${{ secrets.SYNC_TOKEN }}
#       MIN_QUOTA: "1000"          # optional — default 500
#       QUOTA_WRITE_VAR: "true"    # optional — write repo variable
#       QUOTA_REPO: ${{ github.repository }}  # required if QUOTA_WRITE_VAR=true
#     run: |
#       source scripts/includes/quota-snapshot.sh
#       quota_snapshot
#
#   Then gate subsequent steps with:
#     if: steps.quota.outputs.skip == 'false'
#
# GITHUB_OUTPUT keys written:
#   remaining   — integer, current core remaining
#   reset_ts    — unix timestamp of next reset
#   reset_time  — human-readable reset time (HH:MM UTC)
#   skip        — "true" if remaining < MIN_QUOTA, else "false"
#
# Repo variable written (when QUOTA_WRITE_VAR=true):
#   QUOTA_SNAPSHOT — JSON: {"remaining":N,"reset":T,"reset_time":"HH:MM UTC",
#                           "workflow":"NAME","run_id":N,"ts":"ISO8601"}
#   Downstream workflows read this via ${{ vars.QUOTA_SNAPSHOT }} with zero
#   API calls. Useful for chained workflows to know quota state at handoff.
#
# Environment variables (all optional except GH_TOKEN):
#   GH_TOKEN          — GitHub PAT (required)
#   MIN_QUOTA         — skip threshold (default: 500)
#   QUOTA_WRITE_VAR   — "true" to write QUOTA_SNAPSHOT repo variable (default: false)
#   QUOTA_REPO        — owner/repo for variable write (default: $GITHUB_REPOSITORY)
#   QUOTA_SILENT      — "true" to suppress stdout log lines (default: false)
#
# Guard against double-sourcing
[[ -n "${_QUOTA_SNAPSHOT_LOADED:-}" ]] && return 0
_QUOTA_SNAPSHOT_LOADED=1

_qs_info() { [[ "${QUOTA_SILENT:-false}" == "true" ]] || echo "[quota-snapshot] $*" >&2; }

quota_snapshot() {
  local min_quota="${MIN_QUOTA:-500}"
  local write_var="${QUOTA_WRITE_VAR:-false}"
  local repo="${QUOTA_REPO:-${GITHUB_REPOSITORY:-}}"
  local output="${GITHUB_OUTPUT:-/dev/null}"
  local summary="${GITHUB_STEP_SUMMARY:-}"

  # ── Fetch quota ─────────────────────────────────────────────────────────────
  local response remaining reset_ts reset_time
  response=$(curl -sf \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/rate_limit" 2>/dev/null || echo "{}")

  remaining=$(echo "$response" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d.get('resources',{}).get('core',{}).get('remaining',0))" \
    2>/dev/null || echo "0")
  reset_ts=$(echo "$response" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d.get('resources',{}).get('core',{}).get('reset',0))" \
    2>/dev/null || echo "0")
  reset_time=$(python3 -c \
    "import datetime; print(datetime.datetime.utcfromtimestamp(${reset_ts}).strftime('%H:%M UTC'))" \
    2>/dev/null || echo "unknown")

  # ── Determine skip ──────────────────────────────────────────────────────────
  local skip="false"
  if [[ "${remaining}" -lt "${min_quota}" ]]; then
    skip="true"
    _qs_info "Quota too low (${remaining} < ${min_quota}) — skip=true. Resets ${reset_time}."
  else
    _qs_info "Quota OK: ${remaining} remaining (min=${min_quota}). Resets ${reset_time}."
  fi

  # ── Write GITHUB_OUTPUT ─────────────────────────────────────────────────────
  {
    echo "remaining=${remaining}"
    echo "reset_ts=${reset_ts}"
    echo "reset_time=${reset_time}"
    echo "skip=${skip}"
  } >> "$output"

  # ── Write step summary line ─────────────────────────────────────────────────
  if [[ -n "$summary" ]]; then
    local icon="✅"
    [[ "${remaining}" -lt $(( min_quota * 2 )) ]] && icon="⚠️"
    [[ "$skip" == "true" ]] && icon="❌"
    echo "**Quota:** ${icon} ${remaining} remaining — resets ${reset_time}" >> "$summary"
  fi

  # ── Write repo variable (optional) ──────────────────────────────────────────
  if [[ "$write_var" == "true" && -n "$repo" ]]; then
    local workflow="${GITHUB_WORKFLOW:-unknown}"
    local run_id="${GITHUB_RUN_ID:-0}"
    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    local payload
    payload=$(python3 -c "
import json, sys
print(json.dumps({
  'remaining': int(sys.argv[1]),
  'reset':     int(sys.argv[2]),
  'reset_time': sys.argv[3],
  'workflow':  sys.argv[4],
  'run_id':    int(sys.argv[5]),
  'ts':        sys.argv[6],
}, separators=(',',':')))
" "$remaining" "$reset_ts" "$reset_time" "$workflow" "$run_id" "$ts" 2>/dev/null)

    local http_code
    http_code=$(curl -sf -o /dev/null -w "%{http_code}" \
      -X PATCH \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "Content-Type: application/json" \
      "https://api.github.com/repos/${repo}/actions/variables/QUOTA_SNAPSHOT" \
      -d "{\"name\":\"QUOTA_SNAPSHOT\",\"value\":$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$payload")}" \
      2>/dev/null || echo "000")

    # Variable may not exist yet — try POST if PATCH returned 404
    if [[ "$http_code" == "404" ]]; then
      http_code=$(curl -sf -o /dev/null -w "%{http_code}" \
        -X POST \
        -H "Authorization: token ${GH_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -H "Content-Type: application/json" \
        "https://api.github.com/repos/${repo}/actions/variables" \
        -d "{\"name\":\"QUOTA_SNAPSHOT\",\"value\":$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$payload")}" \
        2>/dev/null || echo "000")
    fi

    if [[ "$http_code" == "201" || "$http_code" == "204" ]]; then
      _qs_info "QUOTA_SNAPSHOT variable updated (HTTP ${http_code})"
    else
      _qs_info "QUOTA_SNAPSHOT variable write failed (HTTP ${http_code}) — continuing"
    fi
  fi

  return 0
}
