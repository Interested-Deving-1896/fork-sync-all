#!/usr/bin/env bash
#
# Keeps open PRs in sync with their base branch.
#
# For each open PR in the target repo:
#   1. Check mergeable_state via the GitHub API.
#   2. If "behind" (no conflicts) → auto-update via the update-branch API.
#   3. If "dirty"/"conflicting" → post a comment with rebase instructions.
#   4. Already-current, draft, blocked, or unknown PRs are skipped.
#
# Required env vars:
#   GH_TOKEN    — PAT with repo + pull-requests:write scopes
#   REPO        — owner/repo (e.g. Interested-Deving-1896/fork-sync-all)
#
# Optional env vars:
#   BASE_FILTER   — only process PRs targeting this base branch (default: repo default)
#   PR_FILTER     — comma-separated PR numbers to process (blank = all open PRs)
#   DRY_RUN       — true = report only, no updates or comments (default: false)
#   SKIP_DRAFTS   — true = skip draft PRs (default: true)
#   POST_COMMENTS — true = post a comment on conflicting PRs (default: true)
#   MIN_QUOTA     — minimum REST quota required to start (default: 500)

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

# ── Guards ────────────────────────────────────────────────────────────────────
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_SCRIPT_DIR}/includes/budget.sh"
source "${_SCRIPT_DIR}/includes/gh-api.sh"
source "${_SCRIPT_DIR}/includes/pr-lifecycle.sh"
budget_init

info()  { echo "[rebase-prs] $*" >&2; }
warn()  { echo "[rebase-prs] ⚠  $*" >&2; }
ok()    { echo "[rebase-prs] ✅ $*"; }
fail()  { echo "[rebase-prs] ❌ $*" >&2; }
dry()   { echo "[rebase-prs] [dry-run] $*" >&2; }

# ── Helpers ───────────────────────────────────────────────────────────────────
gh_post() {
  curl -sf -X POST \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    -d "$2" "$1"
}

gh_put_status() {
  curl -sf -X PUT \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    -d "${2:-{}}" \
    -o /dev/null -w "%{http_code}" \
    "$1"
}

post_conflict_comment() {
  local number="$1" head_ref="$2" reason="$3"
  local body
  body=$(HEAD_REF="$head_ref" BASE_TARGET="$base_target" REASON="$reason" \
    python3 -c "
import json, os
head   = os.environ['HEAD_REF']
base   = os.environ['BASE_TARGET']
reason = os.environ['REASON']
msg = (
  '### ⚠️ Manual rebase required\n\n'
  f'This PR cannot be automatically updated: **{reason}**.\n\n'
  'To resolve:\n'
  '\`\`\`bash\n'
  'git fetch origin\n'
  f'git checkout {head}\n'
  f'git rebase origin/{base}\n'
  '# resolve conflicts, then:\n'
  f'git push --force-with-lease origin {head}\n'
  '\`\`\`\n\n'
  '_Posted automatically by \`rebase-prs.yml\`._'
)
print(json.dumps({'body': msg}))
")
  gh_post "${GH_API}/repos/${REPO}/issues/${number}/comments" "$body" > /dev/null \
    && info "  → conflict comment posted on PR #${number}" \
    || warn "  → failed to post conflict comment on PR #${number}"
}

# ── PR lifecycle guard ────────────────────────────────────────────────────────
pr_lifecycle_init "rebase-prs.yml" "rebase-prs"

# ── Quota pre-flight ──────────────────────────────────────────────────────────
remaining=$(gh_get "${GH_API}/rate_limit" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['resources']['core']['remaining'])" \
  || echo 0)

if [[ "${remaining}" -lt "${MIN_QUOTA}" ]]; then
  warn "Quota too low (${remaining} < ${MIN_QUOTA}) — deferring run"
  # Write a sentinel so pr_lifecycle_report clears the var on next success
  pr_lifecycle_defer "__startup__"
  pr_lifecycle_check "__startup__" || true
  exit 0
fi
info "Quota: ${remaining} remaining"

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

# ── Fetch all open PRs into a temp file ──────────────────────────────────────
# One line per PR: "number|head_ref|draft" — avoids all shell quoting issues.
pr_list_file=$(mktemp)
trap 'rm -f "$pr_list_file"' EXIT

page=1
total=0
while true; do
  batch=$(gh_get "${GH_API}/repos/${REPO}/pulls?state=open&base=${base_target}&per_page=100&page=${page}") || break
  count=$(echo "$batch" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
  [[ "$count" -eq 0 ]] && break

  echo "$batch" | python3 -c "
import json, sys
for pr in json.load(sys.stdin):
    num   = pr['number']
    ref   = pr['head']['ref']
    draft = 'true' if pr.get('draft') else 'false'
    # Title: strip newlines and pipes to keep the TSV format safe
    title = pr['title'].replace('\n', ' ').replace('|', '/')
    print(f'{num}|{ref}|{draft}|{title}')
" >> "$pr_list_file"

  total=$(( total + count ))
  [[ "$count" -lt 100 ]] && break
  (( page++ ))
done

info "Found ${total} open PR(s) targeting '${base_target}'"
echo ""

# ── Counters ──────────────────────────────────────────────────────────────────
updated=0
conflicted=0
skipped=0
already_current=0

# ── Process each PR ───────────────────────────────────────────────────────────
while IFS='|' read -r number head_ref draft title; do
  [[ -z "$number" ]] && continue

  budget_check "PR #${number}" || break
  pr_lifecycle_defer "PR #${number}"
  pr_lifecycle_check "PR #${number}" || break

  info "PR #${number}: ${title} (${head_ref})"

  if [[ "$SKIP_DRAFTS" == "true" && "$draft" == "true" ]]; then
    info "  → skipping (draft)"
    (( skipped++ )) || true
    continue
  fi

  if [[ -n "$PR_FILTER" ]] && ! echo ",$PR_FILTER," | grep -q ",${number},"; then
    info "  → skipping (not in PR_FILTER)"
    (( skipped++ )) || true
    continue
  fi

  pr_detail=$(gh_get "${GH_API}/repos/${REPO}/pulls/${number}") || {
    warn "  Could not fetch PR detail — skipping"
    (( skipped++ )) || true
    continue
  }
  mergeable=$(echo "$pr_detail" | python3 -c \
    "import json,sys; print(json.load(sys.stdin).get('mergeable_state','unknown'))" \
    2>/dev/null || echo "unknown")

  info "  mergeable_state: ${mergeable}"

  case "$mergeable" in
    clean)
      info "  → already current and clean"
      (( already_current++ )) || true
      ;;
    behind)
      if [[ "$DRY_RUN" == "true" ]]; then
        dry "would update PR #${number} (${head_ref}) — behind base"
        (( updated++ )) || true
        continue
      fi
      info "  → updating branch (behind base)..."
      http_code=$(gh_put_status \
        "${GH_API}/repos/${REPO}/pulls/${number}/update-branch" \
        '{"expected_head_sha":""}')
      if [[ "$http_code" == "202" || "$http_code" == "200" ]]; then
        ok "  PR #${number} updated (${head_ref} ← ${base_target})"
        (( updated++ )) || true
        pr_lifecycle_done "PR #${number}"
      else
        warn "  update-branch returned HTTP ${http_code} — flagging as conflict"
        [[ "$POST_COMMENTS" == "true" ]] && \
          post_conflict_comment "$number" "$head_ref" "update-branch API returned HTTP ${http_code}"
        (( conflicted++ )) || true
      fi
      ;;
    dirty|conflicting)
      fail "  PR #${number} has conflicts — manual rebase required"
      if [[ "$DRY_RUN" != "true" && "$POST_COMMENTS" == "true" ]]; then
        post_conflict_comment "$number" "$head_ref" "merge conflict with \`${base_target}\`"
      fi
      (( conflicted++ )) || true
      ;;
    blocked|unstable)
      info "  → skipping (${mergeable} — checks or review pending)"
      (( skipped++ )) || true
      ;;
    unknown)
      info "  → skipping (mergeability not yet computed — will catch next run)"
      (( skipped++ )) || true
      ;;
    *)
      info "  → skipping (state: ${mergeable})"
      (( skipped++ )) || true
      ;;
  esac

done < "$pr_list_file"

# ── Summary ───────────────────────────────────────────────────────────────────
pr_lifecycle_report

echo ""
info "========================================"
info " Rebase PRs complete"
info " Updated (auto):    ${updated}"
info " Conflicted:        ${conflicted}"
info " Already current:   ${already_current}"
info " Skipped:           ${skipped}"
if pr_lifecycle_deferred; then
  info " Deferred:          yes (re-queued for next quota window)"
fi
[[ "$DRY_RUN" == "true" ]] && info " (dry run — no changes made)"
budget_report
info "========================================"
