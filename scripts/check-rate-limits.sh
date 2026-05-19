#!/usr/bin/env bash
#
# Queries rate limit status for all external APIs used by fork-sync-all.
#
# Platforms checked:
#   github        — REST API (all resource buckets) + secondary rate limit probe
#   gitlab        — REST API (per-minute authenticated throttle)
#   github-models — models.github.ai inference quota
#
# Required env vars:
#   GH_TOKEN      — SYNC_TOKEN (repo + workflow scopes)
#
# Optional env vars:
#   GITLAB_TOKEN  — GITLAB_SYNC_TOKEN; skipped if unset
#   PLATFORM      — one of: all, github, gitlab, github-models (default: all)
#
# Outputs a Markdown table to $GITHUB_STEP_SUMMARY (when set) and a
# plain-text summary to stdout. Exits non-zero if any platform is at
# or near exhaustion (< 10% remaining).

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"

PLATFORM="${PLATFORM:-all}"
GH_API="https://api.github.com"
GL_API="https://gitlab.com/api/v4"
MODELS_API="https://models.github.ai/inference"

SUMMARY_FILE="${GITHUB_STEP_SUMMARY:-}"
HEADER_TMP=$(mktemp)
trap 'rm -f "$HEADER_TMP"' EXIT

info() { echo "[rate-limits] $*"; }
warn() { echo "[rate-limits] ⚠️  $*" >&2; }

# ── Helpers ───────────────────────────────────────────────────────────────────

# Emit a markdown row: platform | resource | remaining | limit | % | reset
md_row() {
  local platform="$1" resource="$2" remaining="$3" limit="$4" reset_ts="$5"
  # shellcheck disable=SC2034
  local pct=0 bar="" reset_str="—"
  if [[ "$limit" -gt 0 ]]; then
    pct=$(( remaining * 100 / limit ))
  fi
  if [[ "$reset_ts" =~ ^[0-9]+$ && "$reset_ts" -gt 0 ]]; then
    reset_str=$(date -u -d "@${reset_ts}" "+%H:%M UTC" 2>/dev/null \
      || date -u -r "${reset_ts}" "+%H:%M UTC" 2>/dev/null \
      || echo "${reset_ts}")
  fi
  # Status emoji
  local status="✅"
  [[ "$pct" -lt 25 ]] && status="⚠️"
  [[ "$pct" -lt 10 ]] && status="❌"
  echo "| ${status} | \`${platform}\` | ${resource} | ${remaining} | ${limit} | ${pct}% | ${reset_str} |"
}

# Append to step summary if available
summary_append() {
  [[ -n "$SUMMARY_FILE" ]] && echo "$1" >> "$SUMMARY_FILE"
}

# ── GitHub REST API ───────────────────────────────────────────────────────────

check_github() {
  info "Querying GitHub REST API rate limits..."

  local response http_code body
  response=$(curl -s -w "\n%{http_code}" \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -D "$HEADER_TMP" \
    "${GH_API}/rate_limit" 2>/dev/null)
  http_code=$(echo "$response" | tail -1)
  body=$(echo "$response" | sed '$d')

  if [[ "$http_code" != "200" ]]; then
    warn "GitHub API returned HTTP ${http_code}"
    summary_append "| ❌ | \`github\` | REST API | — | — | — | HTTP ${http_code} |"
    return 1
  fi

  # Parse all resource buckets
  echo "$body" | python3 -c "
import sys, json, os
from datetime import datetime, timezone

d = json.load(sys.stdin)
resources = d.get('resources', {})
summary_file = os.environ.get('GITHUB_STEP_SUMMARY', '')

rows = []
low = False
for name, info in sorted(resources.items()):
    remaining = info.get('remaining', 0)
    limit     = info.get('limit', 0)
    reset_ts  = info.get('reset', 0)
    pct = int(remaining * 100 / limit) if limit else 0
    status = '✅' if pct >= 25 else ('⚠️' if pct >= 10 else '❌')
    if pct < 10:
        low = True
    reset_str = datetime.fromtimestamp(reset_ts, tz=timezone.utc).strftime('%H:%M UTC') if reset_ts else '—'
    row = f'| {status} | \`github\` | {name} | {remaining} | {limit} | {pct}% | {reset_str} |'
    rows.append(row)
    print(f'  {status}  {name:<35} {remaining:>6}/{limit:<6}  ({pct}%)  resets {reset_str}')

if summary_file:
    with open(summary_file, 'a') as f:
        for row in rows:
            f.write(row + '\n')

sys.exit(1 if low else 0)
" || return 1
}

# ── GitHub secondary rate limit probe ────────────────────────────────────────
# There is no API endpoint for secondary limits. We probe by checking the
# x-ratelimit-* headers on a lightweight POST (create-then-delete a ref on
# a scratch branch). Instead, we just report the retry-after header if present
# from the last request, and note that secondary limits are per-minute.

check_github_secondary() {
  info "Probing GitHub secondary rate limit..."

  # A lightweight read request — secondary limits only apply to writes,
  # but the response headers tell us if we're currently throttled.
  local response http_code
  response=$(curl -s -w "\n%{http_code}" \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -D "$HEADER_TMP" \
    "${GH_API}/repos/Interested-Deving-1896/fork-sync-all" 2>/dev/null)
  http_code=$(echo "$response" | tail -1)

  local retry_after
  retry_after=$(grep -i "^retry-after:" "$HEADER_TMP" 2>/dev/null | awk '{print $2}' | tr -d '\r' || echo "")

  if [[ "$http_code" == "429" || -n "$retry_after" ]]; then
    warn "Secondary rate limit active — retry after ${retry_after}s"
    summary_append "| ❌ | \`github\` | secondary (per-min writes) | 0 | — | 0% | retry after ${retry_after}s |"
    return 1
  else
    info "  ✅  secondary (per-min writes)         not throttled"
    summary_append "| ✅ | \`github\` | secondary (per-min writes) | — | — | — | not throttled |"
  fi
}

# ── GitLab REST API ───────────────────────────────────────────────────────────

check_gitlab() {
  if [[ -z "${GITLAB_TOKEN:-}" ]]; then
    info "GITLAB_TOKEN not set — skipping GitLab rate limit check"
    summary_append "| ⚠️ | \`gitlab\` | authenticated API | — | — | — | token not set |"
    return 0
  fi

  info "Querying GitLab REST API rate limits..."

  curl -s -o /dev/null \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    -D "$HEADER_TMP" \
    "${GL_API}/user" 2>/dev/null

  local remaining limit reset_ts name
  remaining=$(grep -i "^ratelimit-remaining:" "$HEADER_TMP" 2>/dev/null | awk '{print $2}' | tr -d '\r' || echo "")
  limit=$(grep -i "^ratelimit-limit:" "$HEADER_TMP" 2>/dev/null | awk '{print $2}' | tr -d '\r' || echo "")
  reset_ts=$(grep -i "^ratelimit-reset:" "$HEADER_TMP" 2>/dev/null | awk '{print $2}' | tr -d '\r' || echo "")
  name=$(grep -i "^ratelimit-name:" "$HEADER_TMP" 2>/dev/null | awk '{print $2}' | tr -d '\r' || echo "authenticated_api")

  if [[ -z "$remaining" ]]; then
    warn "No rate limit headers returned from GitLab"
    summary_append "| ⚠️ | \`gitlab\` | ${name} | — | — | — | no headers |"
    return 0
  fi

  local pct=0
  [[ "${limit:-0}" -gt 0 ]] && pct=$(( remaining * 100 / limit ))
  local status="✅"
  [[ "$pct" -lt 25 ]] && status="⚠️"
  [[ "$pct" -lt 10 ]] && status="❌"

  local reset_str="—"
  if [[ "$reset_ts" =~ ^[0-9]+$ && "$reset_ts" -gt 0 ]]; then
    reset_str=$(date -u -d "@${reset_ts}" "+%H:%M UTC" 2>/dev/null \
      || date -u -r "${reset_ts}" "+%H:%M UTC" 2>/dev/null \
      || echo "${reset_ts}")
  fi

  info "  ${status}  ${name}  ${remaining}/${limit}  (${pct}%)  resets ${reset_str}"
  summary_append "| ${status} | \`gitlab\` | ${name} | ${remaining} | ${limit} | ${pct}% | ${reset_str} |"

  [[ "$pct" -lt 10 ]] && return 1 || return 0
}

# ── GitHub Models API ─────────────────────────────────────────────────────────

check_github_models() {
  info "Querying GitHub Models API rate limits..."

  # The models API returns x-ratelimit-* headers on any request.
  # Use a minimal completion request to get current quota.
  local response http_code
  response=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "Content-Type: application/json" \
    -D "$HEADER_TMP" \
    "${MODELS_API}/chat/completions" \
    -d '{"model":"openai/gpt-4o-mini","messages":[{"role":"user","content":"hi"}],"max_tokens":1}' \
    2>/dev/null)
  http_code=$(echo "$response" | tail -1)

  # Parse x-ratelimit headers (GitHub Models uses same header names as REST API)
  # shellcheck disable=SC2034
  local resources=()
  while IFS= read -r line; do
    key=$(echo "$line" | cut -d: -f1 | tr '[:upper:]' '[:lower:]' | tr -d '\r')
    val=$(echo "$line" | cut -d: -f2- | tr -d '\r ' )
    case "$key" in
      x-ratelimit-limit-requests)     rl_limit_req="$val" ;;
      x-ratelimit-remaining-requests) rl_rem_req="$val" ;;
      x-ratelimit-reset-requests)     rl_reset_req="$val" ;;
      x-ratelimit-limit-tokens)       rl_limit_tok="$val" ;;
      x-ratelimit-remaining-tokens)   rl_rem_tok="$val" ;;
      x-ratelimit-reset-tokens)       rl_reset_tok="$val" ;;
    esac
  done < "$HEADER_TMP"

  if [[ "$http_code" == "401" || "$http_code" == "403" ]]; then
    warn "GitHub Models API: HTTP ${http_code} — token may lack models:read scope"
    summary_append "| ❌ | \`github-models\` | requests | — | — | — | HTTP ${http_code} (needs models:read scope) |"
    return 1
  fi

  # Requests quota
  local req_rem="${rl_rem_req:-}" req_lim="${rl_limit_req:-}" req_reset="${rl_reset_req:-}"
  if [[ -n "$req_rem" && -n "$req_lim" ]]; then
    local pct=0
    [[ "$req_lim" -gt 0 ]] && pct=$(( req_rem * 100 / req_lim ))
    local status="✅"
    [[ "$pct" -lt 25 ]] && status="⚠️"
    [[ "$pct" -lt 10 ]] && status="❌"
    info "  ${status}  requests  ${req_rem}/${req_lim}  (${pct}%)  resets ${req_reset:-—}"
    summary_append "| ${status} | \`github-models\` | requests | ${req_rem} | ${req_lim} | ${pct}% | ${req_reset:-—} |"
  else
    info "  ⚠️  requests quota headers not present (HTTP ${http_code})"
    summary_append "| ⚠️ | \`github-models\` | requests | — | — | — | no quota headers (HTTP ${http_code}) |"
  fi

  # Tokens quota
  local tok_rem="${rl_rem_tok:-}" tok_lim="${rl_limit_tok:-}" tok_reset="${rl_reset_tok:-}"
  if [[ -n "$tok_rem" && -n "$tok_lim" ]]; then
    local pct=0
    [[ "$tok_lim" -gt 0 ]] && pct=$(( tok_rem * 100 / tok_lim ))
    local status="✅"
    [[ "$pct" -lt 25 ]] && status="⚠️"
    [[ "$pct" -lt 10 ]] && status="❌"
    info "  ${status}  tokens    ${tok_rem}/${tok_lim}  (${pct}%)  resets ${tok_reset:-—}"
    summary_append "| ${status} | \`github-models\` | tokens | ${tok_rem} | ${tok_lim} | ${pct}% | ${tok_reset:-—} |"
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────

# Write summary header
summary_append "## Rate Limit Status"
summary_append ""
summary_append "| | Platform | Resource | Remaining | Limit | % | Resets |"
summary_append "|---|---|---|---|---|---|---|"

overall_rc=0

case "$PLATFORM" in
  github)
    check_github        || overall_rc=1
    check_github_secondary || overall_rc=1
    ;;
  gitlab)
    check_gitlab        || overall_rc=1
    ;;
  github-models)
    check_github_models || overall_rc=1
    ;;
  all|*)
    check_github        || overall_rc=1
    check_github_secondary || overall_rc=1
    check_gitlab        || overall_rc=1
    check_github_models || overall_rc=1
    ;;
esac

summary_append ""
if [[ "$overall_rc" -eq 0 ]]; then
  summary_append "> ✅ All rate limits healthy."
else
  summary_append "> ❌ One or more rate limits are exhausted or near exhaustion."
fi

info "Done. Exit code: ${overall_rc}"
exit "$overall_rc"
