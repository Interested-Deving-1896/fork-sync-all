#!/usr/bin/env bash
#
# Manages the GitHub Actions run queue to prevent quota exhaustion cascades
# and runner starvation.
#
# Three passes per run:
#
#   1. Dedup — for each workflow, cancel all queued runs except the newest.
#              Keeps the queue shallow so runners aren't wasted on stale work.
#
#   2. Evict  — cancel queued runs that have waited longer than STALE_QUEUE_MIN
#              (default 25 min). A job that can't get a runner in 25 min will
#              be re-queued by rate-limit-rerun or the next schedule tick anyway.
#
#   3. Protect — never cancel runs in PROTECTED_WORKFLOWS regardless of age.
#              These are short, critical jobs (rotate-token, cancel-stale-runs)
#              that must run to completion.
#
# Dry-run mode prints what would be cancelled without acting.
#
# Required env:
#   GH_TOKEN   — PAT with actions:write on REPO
#   REPO       — owner/repo (e.g. Interested-Deving-1896/fork-sync-all)
#
# Optional env:
#   STALE_QUEUE_MIN   — minutes before a queued run is considered stale (default 25)
#   DRY_RUN           — "true" to report without cancelling (default false)
#   MIN_QUOTA         — skip if REST quota below this (default 500)
#   THIS_RUN_ID       — current run ID to never cancel (set by workflow)

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${REPO:?REPO is required}"

STALE_QUEUE_MIN="${STALE_QUEUE_MIN:-25}"
DRY_RUN="${DRY_RUN:-false}"
MIN_QUOTA="${MIN_QUOTA:-500}"
THIS_RUN_ID="${THIS_RUN_ID:-0}"
# FLUSH_ACTIVE — set by flush-lifecycle.yml while the flush pipeline is running.
# When true, queue-manager skips eviction of tier 2 (HIGH) runs so flush stages
# are not cancelled mid-pipeline. Tier 1 (CRITICAL) is always protected.
FLUSH_ACTIVE="${FLUSH_ACTIVE:-${VARS_FLUSH_ACTIVE:-false}}"

info() { echo "[queue-manager] $*" >&2; }
dry()  { echo "[queue-manager][dry-run] $*" >&2; }

# ── Quota pre-flight ──────────────────────────────────────────────────────────

remaining=$(curl -sf \
  -H "Authorization: token ${GH_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/rate_limit" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['resources']['core']['remaining'])" \
  || echo 0)

info "Quota: ${remaining} remaining (min: ${MIN_QUOTA})"

if [[ "${remaining}" -lt "${MIN_QUOTA}" ]]; then
  info "Quota too low — skipping queue management."
  exit 0
fi

# ── Load tier map from config ─────────────────────────────────────────────────
# Tier 1 = protected (never cancelled). Single source of truth:
#   config/workflow-priority-tiers.yml

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIERS_FILE="${SCRIPT_DIR}/../config/workflow-priority-tiers.yml"

# ── Fetch all queued runs ─────────────────────────────────────────────────────

info "Fetching queued runs..."

queued_json=$(python3 - <<PYEOF
import json, urllib.request, os

token = os.environ["GH_TOKEN"]
repo  = os.environ["REPO"]
headers = {
    "Authorization": f"token {token}",
    "Accept": "application/vnd.github+json",
}

runs = []
page = 1
while True:
    url = f"https://api.github.com/repos/{repo}/actions/runs?status=queued&per_page=100&page={page}"
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req) as r:
        data = json.loads(r.read())
    batch = data.get("workflow_runs", [])
    runs.extend(batch)
    if len(batch) < 100:
        break
    page += 1

print(json.dumps(runs))
PYEOF
)

total_queued=$(echo "$queued_json" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
info "Found ${total_queued} queued run(s)."

if [[ "$total_queued" -eq 0 ]]; then
  info "Queue is empty — nothing to do."
  echo "queue_depth=0" >> "${GITHUB_OUTPUT:-/dev/null}"
  echo "cancelled=0"   >> "${GITHUB_OUTPUT:-/dev/null}"
  exit 0
fi

# ── Pass 1: Dedup — keep only newest queued run per workflow ──────────────────
# Pass 2: Evict — cancel runs queued longer than STALE_QUEUE_MIN
# Both passes respect the protected list and THIS_RUN_ID.

# ── FLUSH_ACTIVE TTL check ────────────────────────────────────────────────────
# If FLUSH_ACTIVE=true but the variable was last updated more than 8 hours ago,
# treat it as stale (left set by a force-cancelled lifecycle run) and ignore it.
# The watchdog workflow is the primary fix; this is a belt-and-suspenders fallback.
FLUSH_ACTIVE_TTL_HOURS="${FLUSH_ACTIVE_TTL_HOURS:-8}"
if [[ "${FLUSH_ACTIVE}" == "true" ]]; then
  flush_updated_at=$(gh_get "${GH_API}/repos/${REPO}/actions/variables/FLUSH_ACTIVE" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('updated_at',''))" 2>/dev/null || echo "")
  if [[ -n "${flush_updated_at}" ]]; then
    flush_age_hours=$(python3 -c "
from datetime import datetime, timezone
updated = datetime.fromisoformat('${flush_updated_at}'.replace('Z','+00:00'))
age = (datetime.now(timezone.utc) - updated).total_seconds() / 3600
print(f'{age:.1f}')
" 2>/dev/null || echo "0")
    if python3 -c "import sys; sys.exit(0 if float('${flush_age_hours}') > ${FLUSH_ACTIVE_TTL_HOURS} else 1)" 2>/dev/null; then
      warn "FLUSH_ACTIVE=true but variable is ${flush_age_hours}h old (TTL: ${FLUSH_ACTIVE_TTL_HOURS}h) — treating as stale, ignoring"
      FLUSH_ACTIVE="false"
    else
      info "FLUSH_ACTIVE=true (age: ${flush_age_hours}h) — tier 2 (HIGH) runs are protected from eviction"
    fi
  else
    info "FLUSH_ACTIVE=true — tier 2 (HIGH) runs are protected from eviction"
  fi
fi
info "Running dedup + evict passes (stale threshold: ${STALE_QUEUE_MIN} min)..."

# Write queued_json to a tempfile — avoids env var size limits and shell
# quoting issues when passing large JSON through os.environ.
_qjson_tmp=$(mktemp)
trap 'rm -f "$_qjson_tmp"' EXIT
echo "$queued_json" > "$_qjson_tmp"

cancel_ids=$(THIS_RUN_ID="$THIS_RUN_ID" \
             STALE_QUEUE_MIN="$STALE_QUEUE_MIN" \
             QJSON_FILE="$_qjson_tmp" \
             TIERS_FILE="$TIERS_FILE" \
             FLUSH_ACTIVE="$FLUSH_ACTIVE" \
             python3 - <<'PYEOF'
import json, os, yaml
from datetime import datetime, timezone, timedelta
from collections import defaultdict

with open(os.environ["QJSON_FILE"]) as f:
    runs = json.load(f)

# Load tier map — tier 1 = protected, tier 2 = protected during flush
with open(os.environ["TIERS_FILE"]) as f:
    tiers_cfg = yaml.safe_load(f)

flush_active = os.environ.get("FLUSH_ACTIVE", "false").lower() == "true"

# Build name→tier map
tier_map = {}
for entry in tiers_cfg.get("tiers", []):
    tier_num = entry.get("tier", 3)
    for wf in entry.get("workflows", []):
        name = wf.get("name", wf) if isinstance(wf, dict) else wf
        tier_map[name] = tier_num

def get_tier(name):
    return tier_map.get(name, 3)

# Protected: tier 1 always; tier 2 also protected when flush is active
def is_protected(name):
    t = get_tier(name)
    if t == 1:
        return True
    if flush_active and t == 2:
        return True
    return False

this_run     = int(os.environ.get("THIS_RUN_ID", "0"))
stale_min    = int(os.environ.get("STALE_QUEUE_MIN", "25"))
now          = datetime.now(timezone.utc)
stale_cutoff = now - timedelta(minutes=stale_min)

by_workflow = defaultdict(list)
for run in runs:
    by_workflow[run["name"]].append(run)

to_cancel = {}  # id -> reason

for wf_name, wf_runs in by_workflow.items():
    if is_protected(wf_name):
        continue
    # Sort newest first
    wf_runs.sort(key=lambda r: r["created_at"], reverse=True)
    # Pass 1: dedup — cancel all but the newest
    for run in wf_runs[1:]:
        rid = run["id"]
        if rid == this_run:
            continue
        to_cancel[rid] = f"dedup (newer run exists for '{wf_name}')"
    # Pass 2: evict — cancel newest if it's also stale
    newest = wf_runs[0]
    rid = newest["id"]
    if rid == this_run or rid in to_cancel:
        continue
    created = datetime.fromisoformat(newest["created_at"].replace("Z", "+00:00"))
    if created < stale_cutoff:
        to_cancel[rid] = f"stale (queued {int((now - created).total_seconds() // 60)}min ago)"

for rid, reason in to_cancel.items():
    print(f"{rid}|{reason}")
PYEOF
)

# ── Cancel ────────────────────────────────────────────────────────────────────

cancelled=0
skipped=0

if [[ -z "$cancel_ids" ]]; then
  info "No runs to cancel — queue looks healthy."
else
  while IFS='|' read -r run_id reason; do
    [[ -z "$run_id" ]] && continue
    if [[ "$DRY_RUN" == "true" ]]; then
      dry "Would cancel run ${run_id}: ${reason}"
      (( cancelled++ )) || true
    else
      info "Cancelling run ${run_id}: ${reason}"
      http_code=$(curl -sf -o /dev/null -w "%{http_code}" \
        -X POST \
        -H "Authorization: token ${GH_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${REPO}/actions/runs/${run_id}/cancel" || echo "000")
      if [[ "$http_code" == "202" || "$http_code" == "204" ]]; then
        (( cancelled++ )) || true
      else
        info "Warning: cancel returned HTTP ${http_code} for run ${run_id}"
        (( skipped++ )) || true
      fi
    fi
  done <<< "$cancel_ids"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

info "Done. Cancelled: ${cancelled}, Skipped/protected: ${skipped}, Queue depth was: ${total_queued}"

{
  echo "## Queue Manager"
  echo ""
  echo "| Metric | Value |"
  echo "|---|---|"
  echo "| Queue depth | ${total_queued} |"
  echo "| Cancelled | ${cancelled} |"
  echo "| Protected/skipped | ${skipped} |"
  echo "| Dry run | ${DRY_RUN} |"
  echo "| Stale threshold | ${STALE_QUEUE_MIN} min |"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

echo "queue_depth=${total_queued}" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "cancelled=${cancelled}"      >> "${GITHUB_OUTPUT:-/dev/null}"
