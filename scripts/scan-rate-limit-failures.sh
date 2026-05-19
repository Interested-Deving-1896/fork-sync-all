#!/usr/bin/env bash
#
# Scans recently-failed workflow runs in Interested-Deving-1896/fork-sync-all
# and identifies those that failed specifically due to rate limiting.
#
# For each candidate run:
#   1. Downloads the job logs (zip) via the GitHub API
#   2. Searches for known rate-limit signal patterns
#   3. Extracts the reset epoch (seconds until reset, or absolute epoch)
#   4. Skips runs that were already a rate-limit re-trigger (loop guard)
#   5. Emits a JSON manifest to stdout:
#
#      [
#        {
#          "run_id":       12345,
#          "workflow":     "sync-registered-imports.yml",
#          "name":         "Sync Registered Imports",
#          "reset_epoch":  1779201600,
#          "reset_in_sec": 3600,
#          "patterns":     ["Rate limited — resets in 3600s"]
#        },
#        ...
#      ]
#
# Required env vars:
#   GH_TOKEN      — SYNC_TOKEN (repo scope)
#   GITHUB_OWNER  — default: Interested-Deving-1896
#   GITHUB_REPO   — default: fork-sync-all
#
# Optional env vars:
#   LOOKBACK_HOURS  — how far back to scan (default: 2)
#   MAX_RUNS        — max failed runs to inspect (default: 50)

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"

OWNER="${GITHUB_OWNER:-Interested-Deving-1896}"
REPO="${GITHUB_REPO:-fork-sync-all}"
LOOKBACK_HOURS="${LOOKBACK_HOURS:-2}"
MAX_RUNS="${MAX_RUNS:-50}"
GH_API="https://api.github.com"

info()  { echo "[scan-rl] $*" >&2; }
warn()  { echo "[scan-rl] ⚠️  $*" >&2; }

gh_get() {
  local url="$1"
  curl -s \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "$url"
}

# ── Rate-limit signal patterns ────────────────────────────────────────────────
# These are the exact strings our scripts emit when they hit a rate limit and
# exhaust their internal retry budget. Patterns are matched case-insensitively
# against each line of the job log.
#
# Each pattern may optionally capture a reset value:
#   "resets in Xs"  → extract X as seconds-until-reset
#   "resets at HH:MM UTC" → parse as time-of-day (less precise)
#   "retry after Xs" → extract X as seconds-until-reset

RATE_LIMIT_PATTERNS=(
  "Rate limited — resets in"
  "Rate limited. Backing off"
  "rate limit exceeded"
  "rate-limit.*resets in"
  "\[rate-limit\].*sleeping"
  "API rate limit exceeded"
  "secondary rate limit"
  "You have exceeded a secondary rate limit"
  "ratelimit-remaining: 0"
  "x-ratelimit-remaining: 0"
  "retry-after:"
  "Re-trigger this workflow after the reset"
)

# Pattern that indicates a run was ALREADY a rate-limit re-trigger (loop guard).
# Matches the exact JSON fragment written to INPUTS_JSON by write-summary.sh
# when the workflow was dispatched with rate_limit_rerun=true.
# Must match "true" specifically — every workflow_dispatch run will have
# rate_limit_rerun in INPUTS_JSON (defaulting to "false"), so we cannot
# match on the key name alone.
RERUN_GUARD_PATTERNS=(
  '"rate_limit_rerun": "true"'
  '"rate_limit_rerun":"true"'
)

# ── Helpers ───────────────────────────────────────────────────────────────────

# Download run logs zip to a temp file, return the path
download_logs() {
  local run_id="$1"
  local tmp
  tmp=$(mktemp /tmp/rl-scan-XXXXXX.zip)

  local redirect_url
  redirect_url=$(curl -sI \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${GH_API}/repos/${OWNER}/${REPO}/actions/runs/${run_id}/logs" \
    2>/dev/null | grep -i "^location:" | tr -d '\r' | sed 's/[Ll]ocation: //')

  if [[ -z "$redirect_url" ]]; then
    rm -f "$tmp"
    return 1
  fi

  curl -sL "$redirect_url" -o "$tmp" 2>/dev/null
  if ! python3 -c "import zipfile; zipfile.ZipFile('${tmp}')" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi

  echo "$tmp"
}

# Extract all text from a log zip, return concatenated content
extract_log_text() {
  local zip_path="$1"
  python3 - "$zip_path" << 'PYEOF'
import sys, zipfile

zip_path = sys.argv[1]
with zipfile.ZipFile(zip_path) as z:
    for name in z.namelist():
        if name.endswith('.txt') and '/system' not in name:
            try:
                content = z.read(name).decode('utf-8', errors='replace')
                # Strip timestamps (first 29 chars of each line)
                for line in content.splitlines():
                    print(line[29:] if len(line) > 29 else line)
            except Exception:
                pass
PYEOF
}

# Check if log text contains rate-limit signals; return matched lines
find_rate_limit_signals() {
  local log_text="$1"
  local matched=()

  while IFS= read -r line; do
    for pattern in "${RATE_LIMIT_PATTERNS[@]}"; do
      if echo "$line" | grep -qiE "$pattern"; then
        matched+=("$line")
        break
      fi
    done
  done <<< "$log_text"

  printf '%s\n' "${matched[@]}"
}

# Check if run was already a rate-limit re-trigger (loop guard)
# Check whether a block of log text contains the rate-limit re-trigger guard.
# Called after log extraction so we search the actual job output, where
# write-summary.sh prints INPUTS_JSON containing rate_limit_rerun=true.
is_rerun_guard_in_log() {
  local log_text="$1"
  for guard in "${RERUN_GUARD_PATTERNS[@]}"; do
    if echo "$log_text" | grep -qF "$guard"; then
      return 0
    fi
  done
  return 1
}

# Extract reset epoch from matched signal lines
# Returns Unix epoch (absolute), or 0 if not determinable
extract_reset_epoch() {
  local signals="$1"
  local now
  now=$(date +%s)

  # Pattern: "resets in Xs" or "resets in Xm" or "resets in X seconds"
  local reset_in
  reset_in=$(echo "$signals" | grep -oiE "resets in [0-9]+" | grep -oE "[0-9]+" | head -1)
  if [[ -n "$reset_in" ]]; then
    echo $(( now + reset_in ))
    return
  fi

  # Pattern: "retry after X" or "retry-after: X"
  local retry_after
  retry_after=$(echo "$signals" | grep -oiE "retry.after[: ]+[0-9]+" | grep -oE "[0-9]+" | head -1)
  if [[ -n "$retry_after" ]]; then
    echo $(( now + retry_after ))
    return
  fi

  # Pattern: "resets at HH:MM UTC" — parse as today or tomorrow
  local reset_time
  reset_time=$(echo "$signals" | grep -oiE "resets at [0-9]{2}:[0-9]{2} UTC" | head -1 | grep -oE "[0-9]{2}:[0-9]{2}")
  if [[ -n "$reset_time" ]]; then
    local epoch
    epoch=$(date -u -d "today ${reset_time} UTC" +%s 2>/dev/null || true)
    if [[ -n "$epoch" && "$epoch" -gt "$now" ]]; then
      echo "$epoch"
      return
    fi
    # Already passed today — must be tomorrow
    epoch=$(date -u -d "tomorrow ${reset_time} UTC" +%s 2>/dev/null || true)
    [[ -n "$epoch" ]] && echo "$epoch" && return
  fi

  # Fallback: GitHub primary rate limit resets on the hour
  # Add 65 minutes as a safe buffer
  echo $(( now + 3900 ))
}

# ── Main ──────────────────────────────────────────────────────────────────────

# Compute lookback cutoff (ISO 8601)
CUTOFF=$(date -u -d "${LOOKBACK_HOURS} hours ago" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
  || python3 -c "
from datetime import datetime, timedelta, timezone
cutoff = datetime.now(timezone.utc) - timedelta(hours=${LOOKBACK_HOURS})
print(cutoff.strftime('%Y-%m-%dT%H:%M:%SZ'))
")

info "Scanning failed runs since ${CUTOFF} (lookback: ${LOOKBACK_HOURS}h, max: ${MAX_RUNS})"

# Fetch recent failed runs
RUNS_JSON=$(gh_get \
  "${GH_API}/repos/${OWNER}/${REPO}/actions/runs?status=failure&per_page=${MAX_RUNS}")

TOTAL=$(echo "$RUNS_JSON" | python3 -c "
import sys, json
runs = json.load(sys.stdin).get('workflow_runs', [])
print(len(runs))
" 2>/dev/null || echo 0)

info "Found ${TOTAL} failed runs to inspect"

# Process each run
MANIFEST="[]"

while IFS='|' read -r run_id workflow_name wf_file wf_path created_at; do
  [[ -z "$run_id" ]] && continue

  # Skip runs older than cutoff
  if [[ "$created_at" < "$CUTOFF" ]]; then
    continue
  fi

  info "  Inspecting run ${run_id} (${workflow_name}) created ${created_at}"

  # Download logs
  LOG_ZIP=$(download_logs "$run_id") || {
    warn "    → could not download logs for run ${run_id}"
    continue
  }

  # Extract log text — used for both guard check and signal detection
  LOG_TEXT=$(extract_log_text "$LOG_ZIP")
  rm -f "$LOG_ZIP"

  # Skip if this run was already dispatched by rate-limit-rerun (loop guard).
  # write-summary.sh prints INPUTS_JSON which contains rate_limit_rerun=true
  # when the run was dispatched by rerun-after-rate-limit.sh.
  if is_rerun_guard_in_log "$LOG_TEXT"; then
    info "    → skipped (already a rate-limit re-trigger)"
    continue
  fi

  SIGNALS=$(find_rate_limit_signals "$LOG_TEXT")

  if [[ -z "$SIGNALS" ]]; then
    info "    → no rate-limit signals found"
    continue
  fi

  info "    → rate-limit signals found:"
  while IFS= read -r sig; do
    info "       ${sig}"
  done <<< "$SIGNALS"

  # Extract reset epoch
  RESET_EPOCH=$(extract_reset_epoch "$SIGNALS")
  NOW=$(date +%s)
  RESET_IN=$(( RESET_EPOCH - NOW ))
  [[ "$RESET_IN" -lt 0 ]] && RESET_IN=0

  info "    → reset epoch: ${RESET_EPOCH} (in ${RESET_IN}s)"

  # Append to manifest
  SIGNALS_JSON=$(echo "$SIGNALS" | python3 -c "
import sys, json
lines = [l for l in sys.stdin.read().splitlines() if l.strip()]
print(json.dumps(lines))
")

  MANIFEST=$(echo "$MANIFEST" | python3 -c "
import sys, json
manifest = json.load(sys.stdin)
manifest.append({
    'run_id':          int('${run_id}'),
    'workflow':        '${wf_file}',
    'workflow_path':   '${wf_path}',
    'name':            '${workflow_name}',
    'reset_epoch':     int('${RESET_EPOCH}'),
    'reset_in_sec':    int('${RESET_IN}'),
    'patterns':        ${SIGNALS_JSON}
})
print(json.dumps(manifest, indent=2))
")

done < <(echo "$RUNS_JSON" | python3 -c "
import sys, json
runs = json.load(sys.stdin).get('workflow_runs', [])
for r in runs:
    wf_path = r.get('path', '') or ''
    wf_file = wf_path.split('/')[-1] if wf_path else ''
    print(f\"{r['id']}|{r['name']}|{wf_file}|{wf_path}|{r['created_at']}\")
" 2>/dev/null)

CANDIDATE_COUNT=$(echo "$MANIFEST" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
info "Scan complete — ${CANDIDATE_COUNT} rate-limit candidate(s) found"

# Emit manifest to stdout
echo "$MANIFEST"
