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
# Fetch strategy (auto-detected, no configuration needed):
#   Primary   — GET /orgs/{org}/actions/runs?status=...
#               Requires token with actions:read on the org.
#               Classic PAT with `repo` scope covers this.
#               Fine-grained PAT needs `actions: read` at org level.
#   Fallback  — per-repo queries against the known active repo set
#               (union of registered-imports.json target_names and
#               config/gitlab-subgroups.yml repos). Used automatically
#               when the org endpoint returns 403/404. More expensive
#               (~2 calls per repo) but works with repo-scoped tokens.
#               Bounded to the known set — not all org repos.
#
# Environment variables:
#   GH_TOKEN          — GitHub PAT (required)
#   ORG               — GitHub org to scan (default: Interested-Deving-1896)
#   QUEUE_DEPTH_WARN  — per-workflow queue depth warning threshold (default: 3)
#   QUEUE_DEPTH_CRIT  — per-workflow queue depth critical threshold (default: 8)
#   MAX_QUEUE_AGE_MIN — oldest queued run age (minutes) warning threshold (default: 20)
#   BLOCK_ON_DEPTH    — exit 1 if any workflow exceeds QUEUE_DEPTH_CRIT (default: false)
#   DRY_RUN           — report only, never exit 1 (default: false)

set -euo pipefail

info() { echo "[runner-status] $*" >&2; }
warn() { echo "[runner-status] WARN: $*" >&2; }

ORG="${ORG:-Interested-Deving-1896}"
QUEUE_DEPTH_WARN="${QUEUE_DEPTH_WARN:-3}"
QUEUE_DEPTH_CRIT="${QUEUE_DEPTH_CRIT:-8}"
MAX_QUEUE_AGE_MIN="${MAX_QUEUE_AGE_MIN:-20}"
BLOCK_ON_DEPTH="${BLOCK_ON_DEPTH:-false}"
DRY_RUN="${DRY_RUN:-false}"
GH_API="${GH_API:-https://api.github.com}"

OUTPUT="${GITHUB_OUTPUT:-/dev/null}"
SUMMARY="${GITHUB_STEP_SUMMARY:-}"

# ── Fetch helpers ─────────────────────────────────────────────────────────────

# Paginate a single endpoint, accumulate all workflow_runs into a JSON array.
_paginate_runs() {
  local url_base="$1"
  local page=1
  local all_runs="[]"
  while true; do
    local response
    response=$(curl -sf \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      "${url_base}&per_page=100&page=${page}" \
      2>/dev/null || echo '{}')
    local batch
    batch=$(echo "$response" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(json.dumps(d.get('workflow_runs',[])))
" 2>/dev/null || echo "[]")
    local count
    count=$(echo "$batch" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
    all_runs=$(python3 -c "
import json,sys
print(json.dumps(json.loads(sys.argv[1]) + json.loads(sys.argv[2])))
" "$all_runs" "$batch" 2>/dev/null || echo "$all_runs")
    [[ "$count" -lt 100 ]] && break
    (( page++ ))
  done
  echo "$all_runs"
}

# Probe the org endpoint — returns HTTP status code
_probe_org_endpoint() {
  curl -sf -o /dev/null -w "%{http_code}" \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${GH_API}/orgs/${ORG}/actions/runs?status=queued&per_page=1" \
    2>/dev/null || echo "000"
}

# Fetch via org endpoint (primary path)
_fetch_org() {
  local status="$1"
  _paginate_runs "${GH_API}/orgs/${ORG}/actions/runs?status=${status}"
}

# Fetch via per-repo fallback — queries only the known active repo set
_fetch_per_repo() {
  local status="$1"
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local repo_root
  repo_root="$(cd "${script_dir}/.." && pwd)"

  # Build known repo list from config files
  local repos
  repos=$(python3 - << PYEOF
import json, yaml, os, sys

root = "${repo_root}"
known = set()

try:
    with open(os.path.join(root, 'registered-imports.json')) as f:
        for entry in json.load(f):
            name = entry.get('target_name','').strip()
            if name:
                known.add(name)
except Exception as e:
    print(f"[runner-status] warn: registered-imports.json: {e}", file=sys.stderr)

try:
    with open(os.path.join(root, 'config/gitlab-subgroups.yml')) as f:
        d = yaml.safe_load(f)
    for sg in (d.get('subgroups') or {}).values():
        for repo in (sg.get('repos') or []):
            name = repo.strip() if isinstance(repo, str) else repo.get('name','').strip()
            if name:
                known.add(name)
except Exception as e:
    print(f"[runner-status] warn: gitlab-subgroups.yml: {e}", file=sys.stderr)

for name in sorted(known):
    print(name)
PYEOF
)

  local all_runs="[]"
  local repo_count=0
  while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    local batch
    batch=$(_paginate_runs "${GH_API}/repos/${ORG}/${repo}/actions/runs?status=${status}" 2>/dev/null || echo "[]")
    all_runs=$(python3 -c "
import json,sys
print(json.dumps(json.loads(sys.argv[1]) + json.loads(sys.argv[2])))
" "$all_runs" "$batch" 2>/dev/null || echo "$all_runs")
    (( repo_count++ ))
  done <<< "$repos"

  info "Fallback: queried ${repo_count} repos for status=${status}"
  echo "$all_runs"
}

# ── Auto-detect fetch strategy ────────────────────────────────────────────────
info "Fetching run status for org: ${ORG}"

http_code=$(_probe_org_endpoint)
if [[ "$http_code" == "200" ]]; then
  info "Using org endpoint (HTTP ${http_code})"
  FETCH_MODE="org"
else
  # Per-repo fallback queries every repo individually (225+ calls) and burns the
  # entire quota bucket every hour. Disable it — report unavailable and exit cleanly.
  warn "Org endpoint returned HTTP ${http_code} — token lacks org-level actions:read"
  warn "Skipping per-repo fallback (would burn ~450 REST calls). Grant the token org actions:read to fix."
  echo "## Runner Status — unavailable" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  echo "Org endpoint returned HTTP ${http_code}. Token needs org-level \`actions:read\` scope." >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  exit 0
fi

if [[ "$FETCH_MODE" == "org" ]]; then
  in_progress_json=$(_fetch_org "in_progress")
  queued_json=$(_fetch_org "queued")
else
  in_progress_json=$(_fetch_per_repo "in_progress")
  queued_json=$(_fetch_per_repo "queued")
fi

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
    "in_progress_total": len(in_progress),
    "queued_total":      len(queued),
    "oldest_queue_age_min":   oldest_age_min,
    "oldest_queued_workflow": oldest_workflow,
    "workflows_warning":  warnings,
    "workflows_critical": criticals,
    "rows":    rows,
    "healthy": len(criticals) == 0 and oldest_age_min < max_age_min,
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

info "fetch_mode=${FETCH_MODE}  in_progress=${in_progress_total}  queued=${queued_total}  oldest=${oldest_age}min  healthy=${healthy}"

# ── Write GITHUB_OUTPUT ───────────────────────────────────────────────────────
{
  echo "in_progress_total=${in_progress_total}"
  echo "queued_total=${queued_total}"
  echo "oldest_queue_age_min=${oldest_age}"
  echo "healthy=${healthy}"
  echo "fetch_mode=${FETCH_MODE}"
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
    echo "| Fetch mode | ${FETCH_MODE} |"
    echo ""

    if [[ "$FETCH_MODE" == "per-repo" ]]; then
      echo "> ⚠️ **Fallback mode** — org endpoint unavailable (token lacks org-level \`actions:read\`)."
      echo "> Results are scoped to the known active repo set (registered-imports + gitlab-subgroups)."
      echo "> For complete coverage, use a classic PAT with \`repo\` scope or a fine-grained PAT"
      echo "> with \`actions: read\` at the org level."
      echo ""
    fi

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
