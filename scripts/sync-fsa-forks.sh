#!/usr/bin/env bash
# scripts/sync-fsa-forks.sh — sync downstream fork-sync-all forks with upstream
#
# Reads config/fsa-forks.yml, checks each fork for drift against upstream main,
# and opens a PR on the fork with the delta if it has fallen behind.
# Uses platform-adapter.sh for cross-platform support.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/includes/gh-api.sh"
source "$SCRIPT_DIR/includes/platform-adapter.sh"

info()  { echo "[sync-fsa-forks] $*" >&2; }
warn()  { echo "[sync-fsa-forks][warn] $*" >&2; }
dry()   { echo "[sync-fsa-forks][dry-run] $*" >&2; }

FORKS_CFG="$REPO_ROOT/config/fsa-forks.yml"
FORK_FILTER="${FORK_FILTER:-}"
DRY_RUN="${DRY_RUN:-false}"

[[ -f "$FORKS_CFG" ]] || { warn "config/fsa-forks.yml not found — nothing to sync"; exit 0; }

# ── Parse config ──────────────────────────────────────────────────────────────
upstream_org=$(python3 -c "
import yaml
with open('$FORKS_CFG') as f: c = yaml.safe_load(f)
print(c.get('upstream',{}).get('org',''))
" 2>/dev/null)

upstream_repo=$(python3 -c "
import yaml
with open('$FORKS_CFG') as f: c = yaml.safe_load(f)
print(c.get('upstream',{}).get('repo','fork-sync-all'))
" 2>/dev/null)

upstream_branch=$(python3 -c "
import yaml
with open('$FORKS_CFG') as f: c = yaml.safe_load(f)
print(c.get('upstream',{}).get('branch','main'))
" 2>/dev/null)

info "upstream: ${upstream_org}/${upstream_repo}@${upstream_branch}"

# Get upstream HEAD SHA
upstream_sha=$(gh_get "${GH_API}/repos/${upstream_org}/${upstream_repo}/commits/${upstream_branch}" \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('sha',''))" 2>/dev/null)

[[ -z "$upstream_sha" ]] && { warn "could not resolve upstream SHA — aborting"; exit 1; }
info "upstream HEAD: ${upstream_sha:0:7}"

# ── Process each fork ─────────────────────────────────────────────────────────
synced=0
skipped=0
drifted=0
errors=0

while IFS= read -r fork_json; do
  platform=$(echo "$fork_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('platform','github'))" 2>/dev/null)
  host=$(echo "$fork_json"     | python3 -c "import json,sys; print(json.load(sys.stdin).get('host',''))" 2>/dev/null)
  org=$(echo "$fork_json"      | python3 -c "import json,sys; print(json.load(sys.stdin).get('org',''))" 2>/dev/null)
  repo=$(echo "$fork_json"     | python3 -c "import json,sys; print(json.load(sys.stdin).get('repo','fork-sync-all'))" 2>/dev/null)
  branch=$(echo "$fork_json"   | python3 -c "import json,sys; print(json.load(sys.stdin).get('branch','main'))" 2>/dev/null)
  label=$(echo "$fork_json"    | python3 -c "import json,sys; print(json.load(sys.stdin).get('label',f\"{json.load(open('/dev/stdin'))['org']}/{json.load(open('/dev/stdin'))['repo']}\" if False else json.load(sys.stdin).get('label',''))" 2>/dev/null || echo "${org}/${repo}")
  auto_merge=$(echo "$fork_json" | python3 -c "import json,sys; print(str(json.load(sys.stdin).get('auto_merge',False)).lower())" 2>/dev/null)

  [[ -z "$org" ]] && continue

  # Apply filter
  if [[ -n "$FORK_FILTER" && "${org}/${repo}" != *"$FORK_FILTER"* ]]; then
    info "  SKIP ${label} (filtered)"
    ((skipped++)) || true
    continue
  fi

  info "checking ${label} (${platform}:${org}/${repo}@${branch})"

  # For GitHub forks, use gh_api directly; for others, use platform-adapter
  if [[ "$platform" == "github" ]]; then
    fork_sha=$(gh_get "${GH_API}/repos/${org}/${repo}/commits/${branch}" \
      | python3 -c "import json,sys; print(json.load(sys.stdin).get('sha',''))" 2>/dev/null || echo "")

    if [[ -z "$fork_sha" ]]; then
      warn "  could not resolve ${label} HEAD — skipping"
      ((errors++)) || true
      continue
    fi

    if [[ "$fork_sha" == "$upstream_sha" ]]; then
      info "  UP TO DATE ${label}"
      ((synced++)) || true
      continue
    fi

    # Check if upstream is ahead
    compare=$(gh_get "${GH_API}/repos/${upstream_org}/${upstream_repo}/compare/${fork_sha}...${upstream_sha}" \
      | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('status',''),d.get('ahead_by',0))" 2>/dev/null || echo "error 0")
    status=$(echo "$compare" | awk '{print $1}')
    ahead=$(echo "$compare" | awk '{print $2}')

    if [[ "$status" != "ahead" ]] || [[ "$ahead" -eq 0 ]]; then
      info "  UP TO DATE ${label} (status: $status)"
      ((synced++)) || true
      continue
    fi

    info "  DRIFTED ${label}: upstream is ${ahead} commit(s) ahead"
    ((drifted++)) || true

    if [[ "$DRY_RUN" == "true" ]]; then
      dry "  Would open PR on ${org}/${repo} (${ahead} commits behind upstream)"
      continue
    fi

    # Open a PR on the fork using SYNC_TOKEN (needs write access to the fork)
    pr_body="Upstream fork-sync-all has advanced by **${ahead}** commit(s) since this fork's \`${branch}\` branch was last synced.

**Upstream:** \`${upstream_org}/${upstream_repo}@${upstream_sha:0:7}\`
**Fork HEAD:** \`${org}/${repo}@${fork_sha:0:7}\`

This PR was opened automatically by \`sync-fsa-forks.yml\`. Review and merge to bring this fork up to date.

> Auto-generated by [fork-sync-all](https://github.com/${upstream_org}/${upstream_repo})"

    pr_result=$(curl -sf -X POST \
      -H "Authorization: token ${SYNC_TOKEN:-$GH_TOKEN}" \
      -H "Content-Type: application/json" \
      "${GH_API}/repos/${org}/${repo}/pulls" \
      -d "$(python3 -c "
import json
print(json.dumps({
  'title': 'chore: sync with upstream fork-sync-all@${upstream_sha:0:7}',
  'body': '''${pr_body}''',
  'head': '${upstream_org}:${upstream_branch}',
  'base': '${branch}',
}))
")" 2>/dev/null || echo '{"message":"failed"}')

    pr_num=$(echo "$pr_result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('number',''))" 2>/dev/null || echo "")
    pr_url=$(echo "$pr_result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('html_url',''))" 2>/dev/null || echo "")
    pr_err=$(echo "$pr_result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('message',''))" 2>/dev/null || echo "")

    if [[ -n "$pr_num" ]]; then
      info "  OPENED PR #${pr_num}: ${pr_url}"
      if [[ "$auto_merge" == "true" ]]; then
        info "  auto_merge=true — enabling auto-merge on PR #${pr_num}"
        gh api "repos/${org}/${repo}/pulls/${pr_num}/merge" \
          -X PUT -f merge_method=merge 2>/dev/null \
          && info "  AUTO-MERGED PR #${pr_num}" \
          || warn "  auto-merge failed for PR #${pr_num} (CI may be pending)"
      fi
    elif echo "$pr_err" | grep -qi "already exists"; then
      info "  PR already open for ${label} — skipping"
    else
      warn "  failed to open PR on ${label}: ${pr_err}"
      ((errors++)) || true
    fi

  else
    # Non-GitHub platforms: use platform-adapter for existence check, log drift
    PLATFORM="$platform" PLATFORM_HOST="$host" PLATFORM_TOKEN="${GITLAB_TOKEN:-${GH_TOKEN}}" \
      pa_init "$platform" "$host" 2>/dev/null || true

    if pa_repo_exists "$org" "$repo" 2>/dev/null; then
      info "  EXISTS ${label} on ${platform} — cross-platform PR not yet supported; log only"
      ((drifted++)) || true
    else
      warn "  ${label} not found on ${platform}"
      ((errors++)) || true
    fi
  fi

done < <(python3 -c "
import yaml, json, sys
with open('$FORKS_CFG') as f:
    cfg = yaml.safe_load(f)
for fork in cfg.get('forks', []):
    print(json.dumps(fork))
" 2>/dev/null)

info "done — synced:${synced} drifted:${drifted} skipped:${skipped} errors:${errors}"
