#!/usr/bin/env bash
#
# Reads the JSON manifest produced by scan-rate-limit-failures.sh and
# re-dispatches each identified run after its rate-limit reset epoch.
#
# Uses workflow_dispatch (not rerun-failed-jobs) so that rate_limit_rerun=true
# can be injected as an explicit input — this is the loop guard that prevents
# a second rate-limit failure from triggering a third attempt.
#
# For each entry in the manifest:
#   1. Sleeps until reset_epoch (+ RESET_BUFFER_SEC safety margin)
#   2. Verifies the rate limit has actually recovered
#   3. Reads the workflow file to extract declared input defaults
#   4. Dispatches the workflow with all defaults + rate_limit_rerun=true
#
# Multiple runs sharing the same reset epoch are batched — one sleep covers all.
#
# Required env vars:
#   GH_TOKEN        — SYNC_TOKEN (repo + workflow scopes)
#   MANIFEST_FILE   — path to JSON manifest, or pass via stdin
#
# Optional env vars:
#   GITHUB_OWNER      — default: Interested-Deving-1896
#   GITHUB_REPO       — default: fork-sync-all
#   DRY_RUN           — if "true", print what would happen without dispatching
#   RESET_BUFFER_SEC  — extra seconds after reset epoch before dispatching (default: 60)

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"

OWNER="${GITHUB_OWNER:-Interested-Deving-1896}"
REPO="${GITHUB_REPO:-fork-sync-all}"
DRY_RUN="${DRY_RUN:-false}"
RESET_BUFFER_SEC="${RESET_BUFFER_SEC:-60}"
GH_API="https://api.github.com"

SUMMARY_FILE="${GITHUB_STEP_SUMMARY:-}"

info()  { echo "[rerun-rl] $*"; }
warn()  { echo "[rerun-rl] ⚠️  $*" >&2; }

summary_append() {
  [[ -n "$SUMMARY_FILE" ]] && echo "$1" >> "$SUMMARY_FILE"
}

gh_get() {
  curl -s \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "$1"
}

gh_post() {
  local url="$1" data="$2"
  curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    -d "$data" \
    "$url"
}

# ── Read manifest ─────────────────────────────────────────────────────────────

MANIFEST=""
if [[ -n "${MANIFEST_FILE:-}" && -f "$MANIFEST_FILE" ]]; then
  MANIFEST=$(cat "$MANIFEST_FILE")
else
  MANIFEST=$(cat)
fi

CANDIDATE_COUNT=$(echo "$MANIFEST" | python3 -c "
import sys, json
print(len(json.load(sys.stdin)))
" 2>/dev/null || echo 0)

if [[ "$CANDIDATE_COUNT" -eq 0 ]]; then
  info "No rate-limit candidates to re-dispatch."
  summary_append "## Rate-Limit Re-trigger"
  summary_append ""
  summary_append "> No rate-limit-caused failures found in the scan window."
  exit 0
fi

info "Processing ${CANDIDATE_COUNT} rate-limit candidate(s)"

summary_append "## Rate-Limit Re-trigger"
summary_append ""
summary_append "| Run | Workflow | Reset at | Wait | Result |"
summary_append "|---|---|---|---|---|"

# ── Helpers ───────────────────────────────────────────────────────────────────

# Fetch the workflow file and extract declared input defaults as a JSON object.
# All values are coerced to strings — the workflow_dispatch API accepts only strings.
get_workflow_input_defaults() {
  local wf_path="$1"

  gh_get "${GH_API}/repos/${OWNER}/${REPO}/contents/${wf_path}" \
    | python3 -c "
import sys, json, base64, re

data = json.load(sys.stdin)
if 'content' not in data:
    print('{}')
    sys.exit(0)

content = base64.b64decode(data['content']).decode('utf-8', errors='replace')

in_dispatch   = False
in_inputs     = False
current_input = None
defaults      = {}

for line in content.splitlines():
    stripped = line.lstrip()
    indent   = len(line) - len(stripped)

    if re.match(r'workflow_dispatch\s*:', stripped) and indent == 2:
        in_dispatch = True
        continue

    if in_dispatch and re.match(r'inputs\s*:', stripped) and indent == 4:
        in_inputs = True
        continue

    if in_inputs:
        # Exit inputs block when we reach a sibling or parent key
        if indent <= 4 and stripped and not stripped.startswith('#'):
            if re.match(r'(jobs|permissions|concurrency|env|on)\s*:', stripped):
                break

        # New input name at 6-space indent
        m = re.match(r'^      (\w+)\s*:', line)
        if m:
            current_input = m.group(1)
            if current_input not in defaults:
                defaults[current_input] = ''
            continue

        # default: value under current input (8-space indent)
        if current_input:
            dm = re.match(r'^\s{8}default\s*:\s*(.*)', line)
            if dm:
                val = dm.group(1).strip().strip('\"').strip(\"'\")
                # Coerce booleans to lowercase string for the dispatch API
                if val.lower() in ('true', 'false'):
                    val = val.lower()
                defaults[current_input] = val

print(json.dumps(defaults))
"
}

# Verify GitHub core rate limit has recovered
check_rate_limit_recovered() {
  local remaining
  remaining=$(gh_get "${GH_API}/rate_limit" \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('resources', {}).get('core', {}).get('remaining', 0))
" 2>/dev/null || echo 0)
  info "  GitHub core rate limit remaining: ${remaining}"
  [[ "$remaining" -gt 100 ]]
}

# ── Process candidates ────────────────────────────────────────────────────────

# Sort by reset_epoch so we can batch sleeps
SORTED_MANIFEST=$(echo "$MANIFEST" | python3 -c "
import sys, json
m = json.load(sys.stdin)
m.sort(key=lambda x: x['reset_epoch'])
print(json.dumps(m))
")

dispatches_ok=0
dispatches_skipped=0
dispatches_failed=0
LAST_SLEEP_UNTIL=0

# shellcheck disable=SC2034
while IFS='|' read -r run_id wf_path wf_file name reset_epoch reset_in_sec; do
  [[ -z "$run_id" ]] && continue

  NOW=$(date +%s)
  WAKE_AT=$(( reset_epoch + RESET_BUFFER_SEC ))
  SLEEP_SEC=$(( WAKE_AT - NOW ))
  [[ "$SLEEP_SEC" -lt 0 ]] && SLEEP_SEC=0

  RESET_STR=$(python3 -c "
from datetime import datetime, timezone
print(datetime.fromtimestamp(${reset_epoch}, tz=timezone.utc).strftime('%H:%M UTC'))
" 2>/dev/null || echo "${reset_epoch}")

  info "Run ${run_id} (${name}) — reset at ${RESET_STR}, buffer +${RESET_BUFFER_SEC}s"
  info "  Workflow: ${wf_path}"

  if [[ "$DRY_RUN" == "true" ]]; then
    info "  DRY RUN — would sleep ${SLEEP_SEC}s then dispatch ${wf_file} with rate_limit_rerun=true"
    summary_append "| ${run_id} | \`${wf_file}\` | ${RESET_STR} | ${SLEEP_SEC}s | 🔍 dry-run |"
    (( dispatches_skipped++ )) || true
    continue
  fi

  # Sleep until reset epoch (skip if already slept past this point for a prior batch)
  if [[ "$WAKE_AT" -gt "$LAST_SLEEP_UNTIL" && "$SLEEP_SEC" -gt 0 ]]; then
    info "  Sleeping ${SLEEP_SEC}s until ${RESET_STR} + ${RESET_BUFFER_SEC}s buffer..."
    sleep "$SLEEP_SEC"
    LAST_SLEEP_UNTIL="$WAKE_AT"
  fi

  # Verify rate limit has recovered before dispatching
  if ! check_rate_limit_recovered; then
    warn "  Rate limit still not recovered — skipping run ${run_id}"
    summary_append "| ${run_id} | \`${wf_file}\` | ${RESET_STR} | ${SLEEP_SEC}s | ⚠️ still limited |"
    (( dispatches_skipped++ )) || true
    continue
  fi

  # Read declared input defaults from the workflow file
  info "  Reading input defaults from ${wf_path}..."
  INPUT_DEFAULTS=$(get_workflow_input_defaults "$wf_path")
  info "  Defaults: ${INPUT_DEFAULTS}"

  # Merge defaults with rate_limit_rerun=true (the loop guard)
  DISPATCH_INPUTS=$(echo "$INPUT_DEFAULTS" | python3 -c "
import sys, json
defaults = json.load(sys.stdin)
defaults['rate_limit_rerun'] = 'true'
print(json.dumps(defaults))
")

  DISPATCH_PAYLOAD=$(python3 -c "
import sys, json
inputs = json.loads(sys.argv[1])
print(json.dumps({'ref': 'main', 'inputs': inputs}))
" "$DISPATCH_INPUTS")

  info "  Dispatching ${wf_file}..."

  HTTP_STATUS=$(gh_post \
    "${GH_API}/repos/${OWNER}/${REPO}/actions/workflows/${wf_file}/dispatches" \
    "$DISPATCH_PAYLOAD")

  # workflow_dispatch returns 204 No Content on success
  if [[ "$HTTP_STATUS" == "204" ]]; then
    info "  ✅ Dispatched ${wf_file} (HTTP 204)"
    summary_append "| ${run_id} | \`${wf_file}\` | ${RESET_STR} | ${SLEEP_SEC}s | ✅ dispatched |"
    (( dispatches_ok++ )) || true
  else
    warn "  ❌ Dispatch failed for ${wf_file} (HTTP ${HTTP_STATUS})"
    summary_append "| ${run_id} | \`${wf_file}\` | ${RESET_STR} | ${SLEEP_SEC}s | ❌ HTTP ${HTTP_STATUS} |"
    (( dispatches_failed++ )) || true
  fi

done < <(echo "$SORTED_MANIFEST" | python3 -c "
import sys, json
for e in json.load(sys.stdin):
    wf_path = e.get('workflow_path', '.github/workflows/' + e['workflow'])
    print(f\"{e['run_id']}|{wf_path}|{e['workflow']}|{e['name']}|{e['reset_epoch']}|{e['reset_in_sec']}\")
" 2>/dev/null)

# ── Summary ───────────────────────────────────────────────────────────────────

info ""
info "Done — dispatched: ${dispatches_ok} | skipped: ${dispatches_skipped} | failed: ${dispatches_failed}"

summary_append ""
[[ "$dispatches_ok"      -gt 0 ]] && summary_append "> ✅ ${dispatches_ok} workflow(s) re-dispatched with \`rate_limit_rerun=true\`."
[[ "$dispatches_skipped" -gt 0 ]] && summary_append "> ⚠️  ${dispatches_skipped} skipped (dry-run or still limited)."
[[ "$dispatches_failed"  -gt 0 ]] && summary_append "> ❌ ${dispatches_failed} dispatch(es) failed — check logs."

[[ "$dispatches_failed" -eq 0 ]]
