#!/usr/bin/env bash
#
# Keeps open PRs in sync with their base branch.
#
# For each open PR in the target repo:
#   1. Check if the PR branch is behind its base (mergeable = BEHIND).
#   2. Attempt a clean rebase via the GitHub update-branch API (merge strategy).
#   3. If the update succeeds → report as auto-updated.
#   4. If the update fails (conflict) → post a comment on the PR flagging it
#      for manual rebase, then move on.
#   5. PRs that are already up-to-date or have checks still running are skipped.
#
# The GitHub update-branch API uses a merge commit (not a true rebase) but
# achieves the same result for CI purposes: the PR branch gets the latest
# base branch commits and checks re-run.
#
# Required env vars:
#   GH_TOKEN    — PAT with repo + pull-requests:write scopes
#   REPO        — owner/repo (e.g. Interested-Deving-1896/fork-sync-all)
#
# Optional env vars:
#   BASE_FILTER     — only update PRs targeting this base branch (default: default branch)
#   PR_FILTER       — comma-separated PR numbers to process (blank = all open PRs)
#   DRY_RUN         — true = report only, no updates or comments (default: false)
#   SKIP_DRAFTS     — true = skip draft PRs (default: true)
#   POST_COMMENTS   — true = post a comment on conflicting PRs (default: true)
#   MIN_QUOTA       — minimum REST quota required to start (default: 500)

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${REPO:?REPO is required — owner/repo format}"

GH_API="https://api.github.com"
DRY_RUN="${DRY_RUN:-false}"
SKIP_DRAFTS="${SKIP_DRAFTS:-true}"
POST_COMMENTS="${POST_COMMENTS:-true}"
BASE_FILTER="${BASE_FILTER:-}"
PR_FILTER="${PR_FILTER:-}"
MIN_QUOTA="${MIN_QUOTA:-500}"

# ── Budget guard ──────────────────────────────────────────────────────────────
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_SCRIPT_DIR}/includes/budget.sh"
budget_init

info()  { echo "[rebase-prs] $*" >&2; }
warn()  { echo "[rebase-prs] ⚠  $*" >&2; }
ok()    { echo "[rebase-prs] ✅ $*"; }
fail()  { echo "[rebase-prs] ❌ $*"; }
dry()   { echo "[rebase-prs] [dry-run] $*" >&2; }

updated=0
conflicted=0
skipped=0
already_current=0

# ── Quota pre-flight ──────────────────────────────────────────────────────────
remaining=$(curl -sf \
  -H "Authorization: token ${GH_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "${GH_API}/rate_limit" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['resources']['core']['remaining'])" \
  || echo 0)

if [[ "${remaining}" -lt "${MIN_QUOTA}" ]]; then
  warn "Quota too low (${remaining} < ${MIN_QUOTA}) — skipping run"
  exit 0
fi
info "Quota: ${remaining} remaining"

# ── Helpers ───────────────────────────────────────────────────────────────────
gh_get() {
  curl -sf \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "$1"
}

gh_post() {
  local url="$1" body="$2"
  curl -sf -X POST \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "$url"
}

gh_put() {
  local url="$1" body="${2:-{}}"
  curl -sf -X PUT \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    -d "$body" \
    -w "\n%{http_code}" \
    "$url"
}

# ── Resolve default branch ────────────────────────────────────────────────────
repo_info=$(gh_get "${GH_API}/repos/${REPO}") || {
  fail "Could not fetch repo info for ${REPO}"
  exit 1
}
default_branch=$(echo "$repo_info" | python3 -c \
  "import json,sys; print(json.load(sys.stdin).get('default_branch','main'))")
base_target="${BASE_FILTER:-${default_branch}}"

info "Repo:        ${REPO}"
info "Base branch: ${base_target}"
info "Dry run:     ${DRY_RUN}"
info "Skip drafts: ${SKIP_DRAFTS}"
echo ""

# ── Fetch open PRs ────────────────────────────────────────────────────────────
info "Fetching open PRs targeting '${base_target}'..."

all_prs="[]"
page=1
while true; do
  batch=$(gh_get "${GH_API}/repos/${REPO}/pulls?state=open&base=${base_target}&per_page=100&page=${page}") || break
  count=$(echo "$batch" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
  [[ "$count" -eq 0 ]] && break
  all_prs=$(python3 -c "
import json, sys
a = json.loads('$( echo "$all_prs" | python3 -c "import json,sys; import json; print(json.dumps(json.load(sys.stdin)))" )')
b = json.loads(sys.stdin.read())
print(json.dumps(a + b))
" <<< "$batch" 2>/dev/null || echo "$all_prs")
  [[ "$count" -lt 100 ]] && break
  (( page++ ))
done

total=$(echo "$all_prs" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
info "Found ${total} open PR(s) targeting '${base_target}'"
echo ""

# ── Process each PR ───────────────────────────────────────────────────────────
process_pr() {
  local number="$1" title="$2" head_ref="$3" draft="$4" node_id="$5"

  budget_check "PR #${number}" || return 1

  info "PR #${number}: ${title} (${head_ref})"

  # Skip drafts if configured
  if [[ "$SKIP_DRAFTS" == "true" && "$draft" == "True" ]]; then
    info "  → skipping (draft)"
    (( skipped++ )) || true
    return 0
  fi

  # Apply PR_FILTER if set
  if [[ -n "$PR_FILTER" ]]; then
    if ! echo ",$PR_FILTER," | grep -q ",${number},"; then
      info "  → skipping (not in PR_FILTER)"
      (( skipped++ )) || true
      return 0
    fi
  fi

  # Fetch mergeable state — GitHub computes this lazily, may need a second fetch
  local pr_detail mergeable
  pr_detail=$(gh_get "${GH_API}/repos/${REPO}/pulls/${number}") || {
    warn "  Could not fetch PR detail — skipping"
    (( skipped++ )) || true
    return 0
  }
  mergeable=$(echo "$pr_detail" | python3 -c \
    "import json,sys; print(json.load(sys.stdin).get('mergeable_state','unknown'))" 2>/dev/null || echo "unknown")

  info "  mergeable_state: ${mergeable}"

  case "$mergeable" in
    clean)
      # Already up-to-date with base, checks passing
      info "  → already current and clean"
      (( already_current++ )) || true
      return 0
      ;;
    behind)
      # Behind base but no conflicts — safe to auto-update
      if [[ "$DRY_RUN" == "true" ]]; then
        dry "would update PR #${number} (${head_ref}) — behind base"
        (( updated++ )) || true
        return 0
      fi

      info "  → updating branch (behind base)..."
      local response http_code body
      response=$(gh_put \
        "${GH_API}/repos/${REPO}/pulls/${number}/update-branch" \
        '{"expected_head_sha":""}')
      http_code=$(echo "$response" | tail -1)
      body=$(echo "$response" | head -1)

      if [[ "$http_code" == "202" || "$http_code" == "200" ]]; then
        ok "  PR #${number} updated (${head_ref} ← ${base_target})"
        (( updated++ )) || true
      else
        warn "  Update failed (HTTP ${http_code}): ${body}"
        # Fall through to conflict handling
        _flag_conflict "$number" "$title" "$head_ref" "update-branch API returned HTTP ${http_code}"
        (( conflicted++ )) || true
      fi
      ;;
    dirty|conflicting)
      # Has merge conflicts — needs manual rebase
      fail "  PR #${number} has conflicts — manual rebase required"
      if [[ "$DRY_RUN" != "true" && "$POST_COMMENTS" == "true" ]]; then
        _flag_conflict "$number" "$title" "$head_ref" "merge conflict with \`${base_target}\`"
      fi
      (( conflicted++ )) || true
      ;;
    blocked|unstable)
      # Checks failing or review required — don't touch
      info "  → skipping (${mergeable} — checks or review pending)"
      (( skipped++ )) || true
      ;;
    unknown)
      # GitHub hasn't computed mergeability yet — skip this run, will catch next time
      info "  → skipping (mergeability not yet computed)"
      (( skipped++ )) || true
      ;;
    *)
      info "  → skipping (state: ${mergeable})"
      (( skipped++ )) || true
      ;;
  esac
}

_flag_conflict() {
  local number="$1" title="$2" head_ref="$3" reason="$4"
  local comment
  comment=$(python3 -c "
import json
body = {
  'body': (
    '### ⚠️ Manual rebase required\n\n'
    'This PR cannot be automatically updated: **${reason}**.\n\n'
    'To resolve:\n'
    '\`\`\`bash\n'
    'git fetch origin\n'
    'git checkout ${head_ref}\n'
    'git rebase origin/${base_target}\n'
    '# resolve conflicts, then:\n'
    'git push --force-with-lease origin ${head_ref}\n'
    '\`\`\`\n\n'
    '_This comment was posted automatically by \`rebase-prs.yml\`._'
  )
}
print(json.dumps(body))
")
  gh_post "${GH_API}/repos/${REPO}/issues/${number}/comments" "$comment" > /dev/null \
    && info "  → conflict comment posted on PR #${number}" \
    || warn "  → failed to post conflict comment on PR #${number}"
}

# ── Main loop ─────────────────────────────────────────────────────────────────
echo "$all_prs" | python3 -c "
import json, sys
prs = json.load(sys.stdin)
for pr in prs:
    print(pr['number'], '|||', pr['title'].replace('\n',' '), '|||', pr['head']['ref'], '|||', str(pr.get('draft', False)), '|||', pr['node_id'])
" | while IFS='|||' read -r number title head_ref draft node_id; do
  number=$(echo "$number" | xargs)
  title=$(echo "$title" | xargs)
  head_ref=$(echo "$head_ref" | xargs)
  draft=$(echo "$draft" | xargs)
  node_id=$(echo "$node_id" | xargs)
  process_pr "$number" "$title" "$head_ref" "$draft" "$node_id" || break
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
info "========================================"
info " Rebase PRs complete"
info " Updated (auto):    ${updated}"
info " Conflicted:        ${conflicted}"
info " Already current:   ${already_current}"
info " Skipped:           ${skipped}"
[[ "$DRY_RUN" == "true" ]] && info " (dry run — no changes made)"
budget_report
info "========================================"
