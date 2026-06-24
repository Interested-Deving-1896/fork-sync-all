#!/usr/bin/env bash
# merge-ready-prs.sh — wait for CI then merge all open PRs across repos.
#
# Checks each PR's CI status. If all checks pass (or no checks exist),
# merges with squash. Skips PRs with failing or pending checks.
#
# ── Dev utility ───────────────────────────────────────────────────────────────
# This is a local dev tool — not called by any workflow. Run it manually
# when you want to batch-merge a queue of green PRs without waiting for
# each one individually. Repos are hardcoded below; edit as needed.
#
# Repos checked (override with MERGE_REPOS env var, space-separated owner/repo):
#   Default: fork-sync-all and btrfs-dwarfs-framework under the token owner's org
#
# Usage:
#   export GH_TOKEN=ghp_...
#   ./merge-ready-prs.sh
#   ./merge-ready-prs.sh --dry-run
#   MERGE_REPOS="myorg/repo-a myorg/repo-b" ./merge-ready-prs.sh
set -euo pipefail

export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
DRY_RUN="${DRY_RUN:-false}"
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

if [[ -z "$GH_TOKEN" ]]; then
  echo "ERROR: GH_TOKEN not set" >&2
  exit 1
fi

API="https://api.github.com"
AUTH=(-H "Authorization: token $GH_TOKEN" -H "Accept: application/vnd.github+json")

log() { echo "[$(date -u '+%H:%M:%S')] $*" >&2; }

# ── Rate limit helpers ─────────────────────────────────────────────────────

rate_remaining() {
  curl -s "${AUTH[@]}" "$API/rate_limit" | \
    python3 -c "import json,sys; print(json.load(sys.stdin)['resources']['core']['remaining'])" \
    2>/dev/null || echo 0
}

wait_for_rate_limit() {
  local min="${1:-50}"
  while true; do
    local rem; rem=$(rate_remaining)
    if [[ "$rem" -ge "$min" ]]; then return 0; fi
    local reset now sleep_sec
    reset=$(curl -s "${AUTH[@]}" "$API/rate_limit" | \
      python3 -c "import json,sys,time; r=json.load(sys.stdin)['resources']['core']['reset']; print(max(0,r-int(time.time()))+5)" \
      2>/dev/null || echo 60)
    log "Rate limited (${rem} remaining). Sleeping ${reset}s..."
    sleep "$reset"
  done
}

# ── CI check helpers ───────────────────────────────────────────────────────

# Returns: "success" | "pending" | "failure" | "none"
pr_ci_status() {
  local owner="$1" repo="$2" pr="$3"
  local head_sha
  head_sha=$(curl -s "${AUTH[@]}" "$API/repos/$owner/$repo/pulls/$pr" | \
    python3 -c "import json,sys; print(json.load(sys.stdin)['head']['sha'])" 2>/dev/null)
  [[ -z "$head_sha" ]] && echo "none" && return

  local checks
  checks=$(curl -s "${AUTH[@]}" "$API/repos/$owner/$repo/commits/$head_sha/check-runs?per_page=100" | \
    python3 -c "
import json, sys
d = json.load(sys.stdin)
runs = d.get('check_runs', [])
if not runs:
    print('none')
    sys.exit()
statuses = [r['conclusion'] for r in runs if r['status'] == 'completed']
pending  = [r for r in runs if r['status'] != 'completed']
if pending:
    print('pending')
elif all(s in ('success', 'skipped', 'neutral') for s in statuses):
    print('success')
else:
    failures = [r['name'] for r in runs if r['conclusion'] not in ('success','skipped','neutral',None)]
    print('failure:' + ','.join(failures))
" 2>/dev/null || echo "none")
  echo "$checks"
}

# ── Merge a PR ─────────────────────────────────────────────────────────────

merge_pr() {
  local owner="$1" repo="$2" pr="$3" title="$4"
  if [[ "$DRY_RUN" == "true" ]]; then
    log "  [dry-run] would merge $owner/$repo #$pr: $title"
    return 0
  fi
  local result
  result=$(curl -s -X PUT "${AUTH[@]}" \
    -H "Content-Type: application/json" \
    "$API/repos/$owner/$repo/pulls/$pr/merge" \
    -d "{\"merge_method\":\"squash\",\"commit_title\":\"$title (#$pr)\"}" | \
    python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('merged','false'), d.get('message',''))" \
    2>/dev/null || echo "false error")
  if echo "$result" | grep -q "^True"; then
    log "  ✓ merged: $owner/$repo #$pr"
  else
    log "  ✗ merge failed: $owner/$repo #$pr — $result"
  fi
}

# ── Process a repo ─────────────────────────────────────────────────────────

process_repo() {
  local owner="$1" repo="$2"
  log "=== $owner/$repo ==="

  wait_for_rate_limit 20

  local prs
  prs=$(curl -s "${AUTH[@]}" "$API/repos/$owner/$repo/pulls?state=open&per_page=50" | \
    python3 -c "
import json, sys
for pr in json.load(sys.stdin):
    print(pr['number'], pr['title'].replace('\n',' '))
" 2>/dev/null || echo "")

  if [[ -z "$prs" ]]; then
    log "  No open PRs."
    return
  fi

  while IFS= read -r line; do
    local pr_num pr_title
    pr_num=$(echo "$line" | awk '{print $1}')
    pr_title=$(echo "$line" | cut -d' ' -f2-)

    wait_for_rate_limit 10
    local status
    status=$(pr_ci_status "$owner" "$repo" "$pr_num")

    case "$status" in
      success|none)
        log "  #$pr_num [$status] $pr_title — merging"
        merge_pr "$owner" "$repo" "$pr_num" "$pr_title"
        ;;
      pending)
        log "  #$pr_num [pending] $pr_title — skipping (CI still running)"
        ;;
      failure:*)
        log "  #$pr_num [FAILING] $pr_title — skipping (${status#failure:})"
        ;;
      *)
        log "  #$pr_num [unknown: $status] $pr_title — skipping"
        ;;
    esac
    sleep 2
  done <<< "$prs"
}

# ── Main ───────────────────────────────────────────────────────────────────

log "=== merge-ready-prs ==="
log "Dry run: $DRY_RUN"

wait_for_rate_limit 50

# Resolve default org from the token owner if MERGE_REPOS is not set
if [[ -z "${MERGE_REPOS:-}" ]]; then
  TOKEN_OWNER=$(curl -sf \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/user" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('login',''))" 2>/dev/null || echo "")
  if [[ -z "$TOKEN_OWNER" ]]; then
    echo "ERROR: could not resolve token owner — set MERGE_REPOS=owner/repo" >&2
    exit 1
  fi
  MERGE_REPOS="${TOKEN_OWNER}/fork-sync-all ${TOKEN_OWNER}/btrfs-dwarfs-framework"
fi

for repo_path in $MERGE_REPOS; do
  owner="${repo_path%%/*}"
  repo="${repo_path##*/}"
  process_repo "$owner" "$repo"
done

log "=== Done ==="
