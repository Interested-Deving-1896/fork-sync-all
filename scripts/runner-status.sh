#!/usr/bin/env bash
# scripts/runner-status.sh — runner capacity and queue depth monitor
#
# Fetches all in_progress and queued workflow runs across the org and reports:
#   - Total in_progress (runner utilisation)
#   - Total queued (backlog depth)
#   - Per-workflow breakdown of queued runs
#   - Workflows with queue depth above QUEUE_DEPTH_WARN (default 3)
#   - Oldest queued run age (minutes)
#   - Exit 1 if BLOCK_ON_DEPTH=true and any workflow exceeds QUEUE_DEPTH_CRIT
#
# Writes a Markdown table to GITHUB_STEP_SUMMARY.
# Writes structured outputs to GITHUB_OUTPUT for downstream steps.
#
# Fetch strategy:
#   Uses GET /orgs/{org}/actions/runs?status=... — a single paginated stream
#   that returns runs across all repos in the org. This costs 1 REST call per
#   100 runs (typically 1-2 calls total) regardless of how many repos the org
#   has. The per-repo fallback that previously queried every repo individually
#   (~450 calls/hr) has been removed — it consumed the entire quota bucket.
#
#   If the org endpoint returns non-200 (token lacks org-level actions:read),
#   the script exits cleanly with a step-summary note rather than falling back.
#   Fix: grant the token org-level actions:read (classic PAT with `repo` scope
#   covers this; fine-grained PAT needs `actions: read` at org level).
#
# Quota guard:
#   Checks remaining quota before fetching. Exits cleanly if remaining < MIN_QUOTA
#   (default 100). This prevents burning the first calls of a reset window on a
#   visibility-only script when other workflows need the quota more urgently.
#
# Environment variables:
#   GH_TOKEN          — GitHub PAT (required)
#   ORG               — GitHub org to scan (default: Interested-Deving-1896)
#   MIN_QUOTA         — skip if core remaining < this value (default: 100)
#   QUEUE_DEPTH_WARN  — per-workflow queue depth warning threshold (default: 3)
#   QUEUE_DEPTH_CRIT  — per-workflow queue depth critical threshold (default: 8)
#   MAX_QUEUE_AGE_MIN — oldest queued run age (minutes) warning threshold (default: 20)
#   BLOCK_ON_DEPTH    — exit 1 if any workflow exceeds QUEUE_DEPTH_CRIT (default: false)
#   DRY_RUN           — report only, never exit 1 (default: false)

set -euo pipefail

info() { echo "[runner-status] $*" >&2; }
warn() { echo "[runner-status] WARN: $*" >&2; }

ORG="${ORG:-Interested-Deving-1896}"
MIN_QUOTA="${MIN_QUOTA:-100}"
QUEUE_DEPTH_WARN="${QUEUE_DEPTH_WARN:-3}"
QUEUE_DEPTH_CRIT="${QUEUE_DEPTH_CRIT:-8}"
MAX_QUEUE_AGE_MIN="${MAX_QUEUE_AGE_MIN:-20}"
BLOCK_ON_DEPTH="${BLOCK_ON_DEPTH:-false}"
DRY_RUN="${DRY_RUN:-false}"
GH_API="${GH_API:-https://api.github.com}"

OUTPUT="${GITHUB_OUTPUT:-/dev/null}"
SUMMARY="${GITHUB_STEP_SUMMARY:-}"

# ── Quota guard ───────────────────────────────────────────────────────────────
# Check remaining quota before doing anything. Runner status is visibility-only;
# it should not consume quota that other workflows need more urgently.
remaining=$(curl -sf \
  -H "Authorization: token ${GH_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "${GH_API}/rate_limit" \
  2>/dev/null \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['resources']['core']['remaining'])" \
  2>/dev/null || echo "0")

info "Quota remaining: ${remaining} (min required: ${MIN_QUOTA})"

if [[ "$remaining" -lt "$MIN_QUOTA" ]]; then
  warn "Quota too low (${remaining} < ${MIN_QUOTA}) — skipping to preserve quota for higher-priority workflows."
  {
    echo "in_progress_total=0"
    echo "queued_total=0"
    echo "oldest_queue_age_min=0"
    echo "healthy=true"
    echo "fetch_mode=skipped"
    echo "workflows_critical=none"
    echo "workflows_warning=none"
  } >> "$OUTPUT"
  if [[ -n "$SUMMARY" ]]; then
    {
      echo "## Runner Status — skipped (quota low)"
      echo ""
      echo "Remaining quota (${remaining}) is below threshold (${MIN_QUOTA}). Skipped to preserve quota."
    } >> "$SUMMARY"
  fi
  exit 0
fi

# ── Probe org endpoint ────────────────────────────────────────────────────────
info "Probing org endpoint for: ${ORG}"

probe_code=$(curl -sf -o /dev/null -w "%{http_code}" \
  -H "Authorization: token ${GH_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "${GH_API}/orgs/${ORG}/actions/runs?status=queued&per_page=1" \
  2>/dev/null || echo "000")

if [[ "$probe_code" != "200" ]]; then
  warn "Org endpoint returned HTTP ${probe_code} — token lacks org-level actions:read."
  warn "Fix: classic PAT with 'repo' scope, or fine-grained PAT with 'actions: read' at org level."
  warn "Per-repo fallback removed (burned ~450 REST calls/hr). Exiting cleanly."
  {
    echo "in_progress_total=0"
    echo "queued_total=0"
    echo "oldest_queue_age_min=0"
    echo "healthy=true"
    echo "fetch_mode=unavailable"
    echo "workflows_critical=none"
    echo "workflows_warning=none"
  } >> "$OUTPUT"
  if [[ -n "$SUMMARY" ]]; then
    {
      echo "## Runner Status — unavailable"
      echo ""
      echo "Org endpoint returned HTTP \`${probe_code}\`. Token needs org-level \`actions:read\` scope."
      echo ""
      echo "Fix: classic PAT with \`repo\` scope, or fine-grained PAT with \`actions: read\` at org level."
    } >> "$SUMMARY"
  fi
  exit 0
fi

# ── Fetch runs via org endpoint ───────────────────────────────────────────────
# Single paginated stream across all repos — 1 REST call per 100 runs.
_fetch_org_runs() {
  local status="$1"
  local page=1
  local all_runs="[]"

  while true; do
    local body msg batch count
    body=$(curl -sf \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      "${GH_API}/orgs/${ORG}/actions/runs?status=${status}&per_page=100&page=${page}" \
      2>/dev/null || echo '{"message":"curl_failed"}')

    msg=$(echo "$body" | python3 -c "import json,sys; print(json.load(sys.stdin).get('message',''))" 2>/dev/null || echo "")
    if [[ -n "$msg" ]]; then
      warn "API error fetching ${status} runs (page ${page}): ${msg}" >&2
      break
    fi

    batch=$(echo "$body" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin).get('workflow_runs',[])))" 2>/dev/null || echo "[]")
    count=$(echo "$batch" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
    all_runs=$(python3 -c "import json,sys; print(json.dumps(json.loads(sys.argv[1]) + json.loads(sys.argv[2])))" "$all_runs" "$batch" 2>/dev/null || echo "$all_runs")

    [[ "$count" -lt 100 ]] && break
    (( page++ ))
  done

  echo "$all_runs"
}

info "Fetching runs for org: ${ORG}"
in_progress_json=$(_fetch_org_runs "in_progress")
queued_json=$(_fetch_org_runs "queued")

# ── Analyse ───────────────────────────────────────────────────────────────────
export IN_PROGRESS_JSON="$in_progress_json"
export QUEUED_JSON="$queued_json"

analysis=$(python3 - << 'PYEOF'
import json, sys, os, datetime

in_progress = json.loads(os.environ['IN_PROGRESS_JSON'])
queued      = json.loads(os.environ['QUEUED_JSON'])
warn_depth  = int(os.environ.get('QUEUE_DEPTH_WARN', '3'))
crit_depth  = int(os.environ.get('QUEUE_DEPTH_CRIT', '8'))
max_age_min = int(os.environ.get('MAX_QUEUE_AGE_MIN', '20'))
now         = datetime.datetime.utcnow()

by_workflow = {}
oldest_age_min = 0
oldest_workflow = ""
for run in queued:
    name = run.get('name') or str(run.get('workflow_id', 'unknown'))
    by_workflow.setdefault(name, []).append(run)
    created = run.get('created_at', '')
    if created:
        try:
            dt = datetime.datetime.strptime(created, '%Y-%m-%dT%H:%M:%SZ')
            age = int((now - dt).total_seconds() / 60)
            if age > oldest_age_min:
                oldest_age_min = age
                oldest_workflow = name
        except Exception:
            pass

rows = []
warnings = []
criticals = []
for wf_name, runs in sorted(by_workflow.items(), key=lambda x: -len(x[1])):
    depth = len(runs)
    if depth >= crit_depth:
        flag = "CRIT"
        criticals.append(wf_name)
    elif depth >= warn_depth:
        flag = "WARN"
        warnings.append(wf_name)
    else:
        flag = "OK"
    rows.append({"workflow": wf_name, "queued": depth, "flag": flag})

print(json.dumps({
    "in_progress_total":      len(in_progress),
    "queued_total":           len(queued),
    "oldest_queue_age_min":   oldest_age_min,
    "oldest_queued_workflow": oldest_workflow,
    "workflows_warning":      warnings,
    "workflows_critical":     criticals,
    "rows":                   rows,
    "healthy":                len(criticals) == 0 and oldest_age_min < max_age_min,
}))
PYEOF
)

# ── Parse results ─────────────────────────────────────────────────────────────
in_progress_total=$(echo "$analysis" | python3 -c "import json,sys; print(json.load(sys.stdin)['in_progress_total'])")
queued_total=$(echo "$analysis"      | python3 -c "import json,sys; print(json.load(sys.stdin)['queued_total'])")
oldest_age=$(echo "$analysis"        | python3 -c "import json,sys; print(json.load(sys.stdin)['oldest_queue_age_min'])")
oldest_wf=$(echo "$analysis"         | python3 -c "import json,sys; print(json.load(sys.stdin)['oldest_queued_workflow'])")
healthy=$(echo "$analysis"           | python3 -c "import json,sys; print(json.load(sys.stdin)['healthy'])")
criticals=$(echo "$analysis"         | python3 -c "import json,sys; d=json.load(sys.stdin); print(', '.join(d['workflows_critical']) or 'none')")
warnings_list=$(echo "$analysis"     | python3 -c "import json,sys; d=json.load(sys.stdin); print(', '.join(d['workflows_warning']) or 'none')")

info "in_progress=${in_progress_total}  queued=${queued_total}  oldest=${oldest_age}min  healthy=${healthy}"

# ── Write GITHUB_OUTPUT ───────────────────────────────────────────────────────
{
  echo "in_progress_total=${in_progress_total}"
  echo "queued_total=${queued_total}"
  echo "oldest_queue_age_min=${oldest_age}"
  echo "healthy=${healthy}"
  echo "fetch_mode=org"
  echo "workflows_critical=${criticals}"
  echo "workflows_warning=${warnings_list}"
} >> "$OUTPUT"

# ── Write step summary ────────────────────────────────────────────────────────
if [[ -n "$SUMMARY" ]]; then
  {
    echo "## Runner Status"
    echo ""
    if [[ "$healthy" == "True" ]]; then
      echo "✅ **Healthy** — ${in_progress_total} running, ${queued_total} queued"
    elif [[ "$criticals" != "none" ]]; then
      echo "🔴 **Critical queue depth** — ${in_progress_total} running, ${queued_total} queued"
    else
      echo "⚠️ **Warning** — ${in_progress_total} running, ${queued_total} queued"
    fi
    echo ""
    echo "| Metric | Value |"
    echo "|---|---|"
    echo "| In progress | ${in_progress_total} |"
    echo "| Queued | ${queued_total} |"
    echo "| Oldest queued (min) | ${oldest_age} |"
    [[ -n "$oldest_wf" ]] && echo "| Oldest queued workflow | \`${oldest_wf}\` |"
    echo "| Warn threshold (per workflow) | ${QUEUE_DEPTH_WARN} |"
    echo "| Critical threshold (per workflow) | ${QUEUE_DEPTH_CRIT} |"
    echo "| Fetch mode | org |"
    echo "| Quota remaining | ${remaining} |"
    echo ""

    row_count=$(echo "$analysis" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['rows']))")
    if [[ "$row_count" -gt 0 ]]; then
      echo "### Queued by workflow"
      echo ""
      echo "| Workflow | Queued | Status |"
      echo "|---|---|---|"
      echo "$analysis" | python3 -c "
import json, sys
d = json.load(sys.stdin)
icons = {'OK': '✅', 'WARN': '⚠️', 'CRIT': '🔴'}
for row in d['rows']:
    icon = icons.get(row['flag'], '')
    print(f\"| \`{row['workflow']}\` | {row['queued']} | {icon} {row['flag']} |\")
"
      echo ""
    fi

    if [[ "$criticals" != "none" ]]; then
      echo "> 🔴 **Critical:** ${criticals}"
      echo ">"
      echo "> Queue depth ≥ ${QUEUE_DEPTH_CRIT}. Consider running \`queue-manager.yml\` or \`cancel-stale-runs.yml\`."
      echo ""
    fi
    if [[ "$warnings_list" != "none" ]]; then
      echo "> ⚠️ **Warning:** ${warnings_list}"
      echo ""
    fi
    if [[ "$oldest_age" -ge "$MAX_QUEUE_AGE_MIN" ]]; then
      echo "> ⚠️ Oldest queued run is ${oldest_age} min old (\`${oldest_wf}\`). \`queue-manager.yml\` evicts at ${QUEUE_DEPTH_WARN} min."
      echo ""
    fi
  } >> "$SUMMARY"
fi

# ── Exit code ─────────────────────────────────────────────────────────────────
if [[ "$BLOCK_ON_DEPTH" == "true" && "$DRY_RUN" != "true" && "$criticals" != "none" ]]; then
  warn "Critical queue depth detected: ${criticals}"
  exit 1
fi

info "Done."
