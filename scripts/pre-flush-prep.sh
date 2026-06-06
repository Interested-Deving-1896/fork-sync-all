#!/usr/bin/env bash
#
# scripts/pre-flush-prep.sh — helper for the Pre-Flush Prep workflow
#
# Called by .github/workflows/pre-flush-prep.yml with a single command argument:
#
#   cancel_stale      — cancel queued/in-progress runs older than STALE_MIN
#   merge_ready_prs   — squash-merge open green non-draft PRs into main
#   quota_gate        — wait up to QUOTA_WAIT_MIN for quota >= QUOTA_FLOOR;
#                       sets GITHUB_OUTPUT ready=true|false
#
# Required env vars (set by the workflow):
#   GH_TOKEN        — PAT with repo + actions + workflow scopes
#   REPO            — owner/repo (e.g. Interested-Deving-1896/fork-sync-all)
#   DRY_RUN         — true|false
#   STALE_MIN       — minutes before a run is considered stale (cancel_stale)
#   QUOTA_FLOOR     — minimum remaining quota before flush is safe (quota_gate)
#   QUOTA_WAIT_MIN  — minutes to wait for quota recovery (quota_gate)

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${REPO:?REPO is required}"

GH_API="https://api.github.com"
DRY_RUN="${DRY_RUN:-false}"
STALE_MIN="${STALE_MIN:-10}"
QUOTA_FLOOR="${QUOTA_FLOOR:-3000}"
QUOTA_WAIT_MIN="${QUOTA_WAIT_MIN:-60}"

info() { echo "[pre-flush-prep] $*" >&2; }
warn() { echo "[warn] $*" >&2; }
dry()  { echo "[dry-run] $*" >&2; }

gh_get() {
  curl -sf \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "$1"
}

gh_post() {
  local url="$1" data="${2:-{}}"
  curl -sf -X POST \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    --data "$data" \
    "$url"
}

gh_put() {
  local url="$1" data="${2:-{}}"
  curl -sf -X PUT \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    --data "$data" \
    "$url"
}

quota_remaining() {
  gh_get "${GH_API}/rate_limit" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['resources']['core']['remaining'])" \
    2>/dev/null || echo 0
}

quota_reset_epoch() {
  gh_get "${GH_API}/rate_limit" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['resources']['core']['reset'])" \
    2>/dev/null || echo 0
}

# ── cancel_stale ─────────────────────────────────────────────────────────────
cmd_cancel_stale() {
  info "Cancelling runs queued/in-progress longer than ${STALE_MIN} minutes..."

  local cutoff_epoch
  cutoff_epoch=$(python3 -c "import time; print(int(time.time()) - ${STALE_MIN} * 60)")

  local cancelled=0 skipped=0

  for status in queued in_progress; do
    local page=1
    while true; do
      local runs
      runs=$(gh_get "${GH_API}/repos/${REPO}/actions/runs?status=${status}&per_page=100&page=${page}")
      local count
      count=$(echo "$runs" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('workflow_runs',[])))" 2>/dev/null || echo 0)
      [[ "$count" -eq 0 ]] && break

      while IFS=$'\t' read -r run_id run_name created_at; do
        local created_epoch
        created_epoch=$(python3 -c "
import datetime
dt = datetime.datetime.strptime('${created_at}', '%Y-%m-%dT%H:%M:%SZ')
print(int(dt.replace(tzinfo=datetime.timezone.utc).timestamp()))
" 2>/dev/null || echo 0)

        if [[ "$created_epoch" -le "$cutoff_epoch" ]]; then
          if [[ "$DRY_RUN" == "true" ]]; then
            dry "would cancel run #${run_id} (${run_name}, ${status}, created ${created_at})"
          else
            if curl -sf -X POST \
              -H "Authorization: token ${GH_TOKEN}" \
              -H "Accept: application/vnd.github+json" \
              "${GH_API}/repos/${REPO}/actions/runs/${run_id}/cancel" \
              --data '{}' > /dev/null 2>&1; then
              info "  Cancelled #${run_id} ${run_name}"
              (( cancelled++ )) || true
            else
              warn "  Failed to cancel #${run_id} ${run_name}"
            fi
          fi
        else
          (( skipped++ )) || true
        fi
      done < <(echo "$runs" | python3 -c "
import sys, json
for r in json.load(sys.stdin).get('workflow_runs', []):
    print(r['id'], r['name'], r['created_at'], sep='\t')
")
      (( page++ ))
      [[ "$count" -lt 100 ]] && break
    done
  done

  info "Done — cancelled=${cancelled} skipped=${skipped}"
}

# ── merge_ready_prs ──────────────────────────────────────────────────────────
cmd_merge_ready_prs() {
  info "Checking for open green non-draft PRs to merge into main..."

  local merged=0 skipped=0

  local prs
  prs=$(gh_get "${GH_API}/repos/${REPO}/pulls?state=open&base=main&per_page=100")

  while IFS=$'\t' read -r pr_num pr_title draft mergeable_state head_sha; do
    # Skip drafts
    if [[ "$draft" == "True" ]]; then
      info "  #${pr_num} skipped — draft"
      (( skipped++ )) || true
      continue
    fi

    # Skip if not clean
    if [[ "$mergeable_state" != "clean" ]]; then
      info "  #${pr_num} skipped — mergeable_state=${mergeable_state}"
      (( skipped++ )) || true
      continue
    fi

    # Check all checks passed
    local check_result
    check_result=$(gh_get "${GH_API}/repos/${REPO}/commits/${head_sha}/check-runs" \
      | python3 -c "
import sys, json
runs = json.load(sys.stdin).get('check_runs', [])
failed = [r['name'] for r in runs if r['status']=='completed' and r.get('conclusion') not in ('success','skipped','neutral','')]
pending = [r['name'] for r in runs if r['status'] != 'completed']
if failed: print('failed:' + ','.join(failed))
elif pending: print('pending:' + ','.join(pending))
else: print('green')
" 2>/dev/null || echo "unknown")

    if [[ "$check_result" != "green" ]]; then
      info "  #${pr_num} skipped — checks: ${check_result}"
      (( skipped++ )) || true
      continue
    fi

    # Merge
    if [[ "$DRY_RUN" == "true" ]]; then
      dry "would squash-merge PR #${pr_num}: ${pr_title}"
    else
      local result
      result=$(gh_put \
        "${GH_API}/repos/${REPO}/pulls/${pr_num}/merge" \
        '{"merge_method":"squash"}' 2>/dev/null || echo '{"message":"error"}')
      local msg
      msg=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('message','?'))" 2>/dev/null || echo "?")
      if echo "$msg" | grep -qi "merged\|success"; then
        info "  #${pr_num} merged — ${pr_title}"
        (( merged++ )) || true
      else
        warn "  #${pr_num} merge failed — ${msg}"
        (( skipped++ )) || true
      fi
    fi
    sleep 2
  done < <(echo "$prs" | python3 -c "
import sys, json
for pr in json.load(sys.stdin):
    print(pr['number'], pr['title'][:60], pr['draft'], pr.get('mergeable_state','?'), pr['head']['sha'], sep='\t')
")

  info "Done — merged=${merged} skipped=${skipped}"
}

# ── quota_gate ───────────────────────────────────────────────────────────────
cmd_quota_gate() {
  local floor="${QUOTA_FLOOR}"
  local wait_min="${QUOTA_WAIT_MIN}"
  local waited=0
  local interval=60  # check every 60s

  info "Quota gate — need ${floor} remaining (will wait up to ${wait_min} min)"

  while true; do
    local remaining
    remaining=$(quota_remaining)
    info "  Quota: ${remaining} remaining"

    if [[ "$remaining" -ge "$floor" ]]; then
      info "  ✅ Quota sufficient — proceeding"
      echo "ready=true" >> "${GITHUB_OUTPUT:-/dev/null}"
      return 0
    fi

    if [[ "$wait_min" -eq 0 ]] || [[ "$waited" -ge "$wait_min" ]]; then
      warn "  ❌ Quota insufficient (${remaining} < ${floor}) after waiting ${waited} min — aborting flush"
      echo "ready=false" >> "${GITHUB_OUTPUT:-/dev/null}"
      return 1
    fi

    # Calculate time to next reset
    local reset_epoch now_epoch secs_to_reset
    reset_epoch=$(quota_reset_epoch)
    now_epoch=$(date +%s)
    secs_to_reset=$(( reset_epoch - now_epoch + 5 ))

    if [[ "$secs_to_reset" -gt 0 ]] && [[ "$secs_to_reset" -le $(( wait_min * 60 - waited * 60 )) ]]; then
      info "  Quota reset in ${secs_to_reset}s — waiting..."
      sleep "$secs_to_reset"
      waited=$(( waited + secs_to_reset / 60 + 1 ))
    else
      info "  Waiting ${interval}s before retry (${waited}/${wait_min} min elapsed)..."
      sleep "$interval"
      (( waited++ )) || true
    fi
  done
}

# ── dispatch ─────────────────────────────────────────────────────────────────
CMD="${1:-}"
case "$CMD" in
  cancel_stale)    cmd_cancel_stale ;;
  merge_ready_prs) cmd_merge_ready_prs ;;
  quota_gate)      cmd_quota_gate ;;
  *)
    echo "Usage: $0 {cancel_stale|merge_ready_prs|quota_gate}" >&2
    exit 1
    ;;
esac
