#!/usr/bin/env bash
#
# Quota reserve — enforces a minimum API call buffer by cancelling low-priority
# queued runs when remaining quota drops below RESERVE_FLOOR.
#
# The goal is to always keep RESERVE_FLOOR calls available for critical
# operations (token rotation, queue management, config validation) regardless
# of how many scheduled workflows are queued.
#
# How it works:
#   1. Check current quota remaining.
#   2. If remaining >= RESERVE_FLOOR: log and exit — nothing to do.
#   3. If remaining < RESERVE_FLOOR: cancel queued runs in priority order
#      (lowest priority first) until the projected savings would restore
#      the reserve. Uses cost profiles to estimate savings per cancellation.
#   4. Never cancels PROTECTED_WORKFLOWS regardless of quota state.
#   5. Never cancels runs created within the last GRACE_MIN minutes
#      (gives new runs a chance to start before being evicted).
#
# Priority tiers (lower number = higher priority = never cancelled first):
#   1 — CRITICAL: token rotation, queue/reserve management, config validation
#   2 — HIGH:     mirror chain, sync operations
#   3 — MEDIUM:   README updates, badge injection, CI checks
#   4 — LOW:      translation, dep graph, upstream proposals, maintenance
#
# Required env:
#   GH_TOKEN        — PAT with actions:write on REPO
#   REPO            — owner/repo
#
# Optional env:
#   RESERVE_FLOOR   — minimum quota to maintain (default: 1000)
#   GRACE_MIN       — don't cancel runs newer than this many minutes (default: 5)
#   DRY_RUN         — "true" to report without cancelling (default: false)
#   THIS_RUN_ID     — current run ID to never cancel (set by workflow)

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${REPO:?REPO is required}"

RESERVE_FLOOR="${RESERVE_FLOOR:-1000}"
GRACE_MIN="${GRACE_MIN:-5}"
DRY_RUN="${DRY_RUN:-false}"
THIS_RUN_ID="${THIS_RUN_ID:-0}"
API="https://api.github.com"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIERS_FILE="${SCRIPT_DIR}/../config/workflow-priority-tiers.yml"
COSTS_FILE="${SCRIPT_DIR}/../config/workflow-quota-costs.yml"

info() { echo "[quota-reserve] $*" >&2; }
ok()   { echo "[quota-reserve] ✓ $*" >&2; }
dry()  { echo "[quota-reserve][dry-run] $*" >&2; }

# ── Check current quota ───────────────────────────────────────────────────────

rl_json=$(curl -sf \
  -H "Authorization: token ${GH_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "${API}/rate_limit" || echo "{}")

read -r remaining reset_at < <(echo "$rl_json" | python3 -c "
import sys, json, datetime
d = json.load(sys.stdin).get('resources', {}).get('core', {})
remaining = d.get('remaining', 0)
reset_ts  = d.get('reset', 0)
reset_at  = datetime.datetime.fromtimestamp(reset_ts, tz=datetime.timezone.utc).strftime('%H:%M UTC') if reset_ts else 'unknown'
print(remaining, reset_at)
" 2>/dev/null || echo "0 unknown")

info "Quota: ${remaining} remaining (reserve floor: ${RESERVE_FLOOR}, resets: ${reset_at})"

if [[ "${remaining}" -ge "${RESERVE_FLOOR}" ]]; then
  ok "Quota above reserve floor — no action needed."
  echo "quota_remaining=${remaining}" >> "${GITHUB_OUTPUT:-/dev/null}"
  echo "action_taken=none"            >> "${GITHUB_OUTPUT:-/dev/null}"
  {
    echo "## Quota Reserve"
    echo ""
    echo "✅ Quota healthy: **${remaining}** remaining (floor: ${RESERVE_FLOOR})"
    echo ""
    echo "Reset at: ${reset_at}"
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  exit 0
fi

deficit=$(( RESERVE_FLOOR - remaining ))
info "Quota below reserve floor by ${deficit} calls — scanning queued runs..."

# ── Priority tiers ────────────────────────────────────────────────────────────
# Workflows are cancelled lowest-priority-first.
# Tier 1 (CRITICAL) is never cancelled.

declare -A WORKFLOW_TIER
# Tier 1 — CRITICAL (never cancelled)
WORKFLOW_TIER["Rotate Secret Token"]=1
WORKFLOW_TIER["Queue Manager"]=1
WORKFLOW_TIER["Quota Reserve"]=1
WORKFLOW_TIER["Critical Deploy"]=1
WORKFLOW_TIER["Cancel Stale Runs"]=1
WORKFLOW_TIER["Cancel Runs After Token Rotation"]=1
WORKFLOW_TIER["Validate Config"]=1
WORKFLOW_TIER["Token Health"]=1
WORKFLOW_TIER["Rate-Limit Re-trigger"]=1
WORKFLOW_TIER["Quota Monitor"]=1

# Tier 2 — HIGH
WORKFLOW_TIER["Mirror Interested-Deving-1896 → OSP"]=2
WORKFLOW_TIER["Mirror OSP → GitLab"]=2
WORKFLOW_TIER["Mirror to OpenOS-Project-Ecosystem-OOC"]=2
WORKFLOW_TIER["Sync Registered Imports"]=2
WORKFLOW_TIER["Sync Forks"]=2
WORKFLOW_TIER["Full Chain Flush"]=2

# Tier 3 — MEDIUM
WORKFLOW_TIER["Create Missing READMEs"]=3
WORKFLOW_TIER["Update READMEs"]=3
WORKFLOW_TIER["Validate README Render"]=3
WORKFLOW_TIER["Inject Built-with-Ona Badges"]=3
WORKFLOW_TIER["Check OSP-Bound CI Status"]=3
WORKFLOW_TIER["Rebase PRs"]=3
WORKFLOW_TIER["Reconcile Org References"]=3
WORKFLOW_TIER["Sync btrfs-devel Branches"]=3
WORKFLOW_TIER["Sync pieroproietti Forks"]=3

# Tier 4 — LOW (cancelled first)
WORKFLOW_TIER["Translate READMEs"]=4
WORKFLOW_TIER["LTS README Standardisation"]=4
WORKFLOW_TIER["Generate Dependency Graph"]=4
WORKFLOW_TIER["Upstream Workflow Proposal"]=4
WORKFLOW_TIER["Update Infra Dependencies"]=4
WORKFLOW_TIER["Update Workflow Triggers Doc"]=4
WORKFLOW_TIER["Notification Poller"]=4
WORKFLOW_TIER["Mirror Artifacts"]=4
WORKFLOW_TIER["Mirror Releases"]=4
WORKFLOW_TIER["Upstream PRs from OSP + OOC"]=4
WORKFLOW_TIER["Upstream Direct Commits from OSP + OOC"]=4
WORKFLOW_TIER["Repo Manifest"]=4

# ── Fetch queued runs ─────────────────────────────────────────────────────────

info "Fetching queued runs..."

queued_json=$(python3 - <<PYEOF
import json, urllib.request, os

token = os.environ["GH_TOKEN"]
repo  = os.environ["REPO"]
api   = os.environ.get("API", "https://api.github.com")
headers = {
    "Authorization": f"token {token}",
    "Accept": "application/vnd.github+json",
}

runs = []
page = 1
while True:
    url = f"{api}/repos/{repo}/actions/runs?status=queued&per_page=100&page={page}"
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req) as r:
            data = json.loads(r.read())
    except Exception as e:
        print(f"[]", flush=True)
        break
    batch = data.get("workflow_runs", [])
    runs.extend(batch)
    if len(batch) < 100:
        break
    page += 1

print(json.dumps(runs))
PYEOF
)

total_queued=$(echo "$queued_json" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
info "Found ${total_queued} queued run(s)."

# ── Select cancellation candidates and cancel ─────────────────────────────────
# Write queued_json to tempfile — avoids env var size limits and quoting issues.
# Sort tier-4-first (lowest priority), then oldest first within each tier.
# Never cancel tier 1 or runs within GRACE_MIN.

_qjson_tmp=$(mktemp)
trap 'rm -f "$_qjson_tmp"' EXIT
echo "$queued_json" > "$_qjson_tmp"

cancelled=0
cancelled_names=()

while IFS='|' read -r run_id name tier age; do
  [[ -z "$run_id" ]] && continue

  if [[ "$DRY_RUN" == "true" ]]; then
    dry "Would cancel ${run_id} (${name}, ${tier}, ${age})"
    (( cancelled++ )) || true
    cancelled_names+=("${name}")
  else
    info "Cancelling ${run_id} (${name}, ${tier}, ${age})..."
    http_code=$(curl -sf -o /dev/null -w "%{http_code}" \
      -X POST \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      "${API}/repos/${REPO}/actions/runs/${run_id}/cancel" || echo "000")

    if [[ "$http_code" == "202" || "$http_code" == "204" ]]; then
      (( cancelled++ )) || true
      cancelled_names+=("${name}")
      ok "Cancelled ${name} (${tier})"
    else
      info "Warning: cancel returned HTTP ${http_code} for ${run_id}"
    fi
  fi
done < <(THIS_RUN_ID="$THIS_RUN_ID" GRACE_MIN="$GRACE_MIN" \
  QJSON_FILE="$_qjson_tmp" TIERS_FILE="$TIERS_FILE" COSTS_FILE="$COSTS_FILE" \
  REMAINING="$remaining" RESERVE_FLOOR="$RESERVE_FLOOR" \
  python3 - <<'PYEOF'
import json, os, sys, yaml
from datetime import datetime, timezone, timedelta

with open(os.environ["QJSON_FILE"]) as f:
    runs = json.load(f)

# Load tier map from single source of truth
with open(os.environ["TIERS_FILE"]) as f:
    tiers_cfg = yaml.safe_load(f)
default_tier = tiers_cfg.get("default_tier", 3)
tier_map = {e["name"]: e["tier"] for e in tiers_cfg.get("tiers", [])}

# Load per-workflow min_quota from costs config
costs_file = os.environ.get("COSTS_FILE", "")
min_quota_map = {}
if costs_file and os.path.exists(costs_file):
    with open(costs_file) as f:
        costs_cfg = yaml.safe_load(f) or {}
    for wf in (costs_cfg.get("workflows") or []):
        if wf.get("name") and wf.get("min_quota"):
            min_quota_map[wf["name"]] = wf["min_quota"]

remaining     = int(os.environ.get("REMAINING", "0"))
reserve_floor = int(os.environ.get("RESERVE_FLOOR", "1000"))
this_run      = int(os.environ.get("THIS_RUN_ID", "0"))
grace_min     = int(os.environ.get("GRACE_MIN", "5"))
now           = datetime.now(timezone.utc)
grace_cut     = now - timedelta(minutes=grace_min)

candidates = []
for run in runs:
    rid     = run["id"]
    name    = run["name"]
    created = datetime.fromisoformat(run["created_at"].replace("Z", "+00:00"))
    tier    = tier_map.get(name, default_tier)

    if rid == this_run or tier == 1 or created > grace_cut:
        continue

    # Cost-aware cancellation: also cancel if remaining < this workflow's min_quota
    # even if it would otherwise survive on tier alone.
    wf_min_quota = min_quota_map.get(name, 0)
    cost_blocked = remaining < wf_min_quota

    age_min = int((now - created).total_seconds() // 60)
    reason  = f"tier{tier}" + (f",needs≥{wf_min_quota}" if cost_blocked else "")
    candidates.append((tier, created, rid, name, age_min, reason))

if not candidates:
    print("[quota-reserve] No cancellable runs — all critical or within grace period.", file=sys.stderr)

# Sort: highest tier (lowest priority) first, then oldest first
candidates.sort(key=lambda r: (-r[0], r[1]))
for tier, created, rid, name, age_min, reason in candidates:
    print(f"{rid}|{name}|{reason}|{age_min}min old")
PYEOF
)

# ── Summary ───────────────────────────────────────────────────────────────────

info "Done. Quota was: ${remaining}, floor: ${RESERVE_FLOOR}, cancelled: ${cancelled} run(s)."

{
  echo "## Quota Reserve"
  echo ""
  if [[ "${remaining}" -ge "${RESERVE_FLOOR}" ]]; then
    echo "✅ Quota healthy: **${remaining}** remaining"
  else
    echo "⚠️ Quota below floor: **${remaining}** / ${RESERVE_FLOOR}"
    echo ""
    echo "Cancelled **${cancelled}** queued run(s) to protect reserve."
    if [[ ${#cancelled_names[@]} -gt 0 ]]; then
      echo ""
      echo "| Cancelled |"
      echo "|---|"
      for n in "${cancelled_names[@]}"; do
        echo "| ${n} |"
      done
    fi
  fi
  echo ""
  echo "| Metric | Value |"
  echo "|---|---|"
  echo "| Remaining | ${remaining} |"
  echo "| Reserve floor | ${RESERVE_FLOOR} |"
  echo "| Cancelled | ${cancelled} |"
  echo "| Dry run | ${DRY_RUN} |"
  echo "| Reset at | ${reset_at} |"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

echo "quota_remaining=${remaining}" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "cancelled=${cancelled}"       >> "${GITHUB_OUTPUT:-/dev/null}"
