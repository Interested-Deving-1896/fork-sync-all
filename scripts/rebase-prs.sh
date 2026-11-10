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
#   UPDATE_METHOD — merge (default) or rebase
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
UPDATE_METHOD="${UPDATE_METHOD:-merge}"
MIN_QUOTA="${MIN_QUOTA:-500}"

if [[ "$UPDATE_METHOD" != "merge" && "$UPDATE_METHOD" != "rebase" ]]; then
  echo "[update-branches] ERROR: UPDATE_METHOD must be 'merge' or 'rebase' (got '$UPDATE_METHOD')" >&2
  exit 2
fi

# Defense in depth: the workflow must never use a caller-supplied repository
# target, and write-capable events must execute from the default branch.
if [[ -n "${GITHUB_REPOSITORY:-}" && "$REPO" != "$GITHUB_REPOSITORY" ]]; then
  echo "[update-branches] ERROR: refusing target '$REPO'; expected '$GITHUB_REPOSITORY'" >&2
  exit 2
fi
if [[ -n "${DEFAULT_BRANCH:-}" && -n "${GITHUB_REF:-}" &&
      "$GITHUB_REF" != "refs/heads/$DEFAULT_BRANCH" ]]; then
  echo "[update-branches] ERROR: refusing write from non-default ref '$GITHUB_REF'" >&2
  exit 2
fi
if [[ "${GITHUB_EVENT_NAME:-}" == "workflow_run" &&
      "${WORKFLOW_RUN_CONCLUSION:-}" != "success" ]]; then
  echo "[update-branches] ERROR: refusing unsuccessful workflow_run trigger" >&2
  exit 2
fi

# ── Guards ────────────────────────────────────────────────────────────────────
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_SCRIPT_DIR}/includes/budget.sh"
source "${_SCRIPT_DIR}/includes/gh-api.sh"
source "${_SCRIPT_DIR}/includes/pr-lifecycle.sh"
budget_init

info()  { echo "[update-branches] $*" >&2; }
warn()  { echo "[update-branches] ⚠  $*" >&2; }
ok()    { echo "[update-branches] ✅ $*"; }
fail()  { echo "[update-branches] ❌ $*" >&2; }
dry()   { echo "[update-branches] [dry-run] $*" >&2; }

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
  body=$(HEAD_REF="$head_ref" BASE_TARGET="$base_target" REASON="$reason" UPDATE_METHOD="$UPDATE_METHOD" \
    python3 -c "
import json, os
head = os.environ['HEAD_REF']
base = os.environ['BASE_TARGET']
reason = os.environ['REASON']
method = os.environ['UPDATE_METHOD']
command = f'git rebase origin/{base}' if method == 'rebase' else f'git merge origin/{base}'
push = f'git push --force-with-lease origin {head}' if method == 'rebase' else f'git push origin {head}'
fence = chr(96) * 3
msg = (
  '### ⚠️ Manual branch update required\n\n'
  f'This PR cannot be automatically updated: **{reason}**.\n\n'
  f'The configured update method is **{method}**. To resolve:\n'
  f'{fence}bash\n'
  'git fetch origin\n'
  f'git checkout {head}\n'
  f'{command}\n'
  '# resolve conflicts, then:\n'
  f'{push}\n'
  f'{fence}\n\n'
  'Posted automatically by rebase-prs.yml.'
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

# ── Fetch and validate the complete PR snapshot before any writes ─────────────
# API/listing errors or malformed entries abort the run. We never process a
# partial page set, and we retain exact refs so each candidate can be rechecked.
pr_list_file=$(mktemp)
page_file=$(mktemp)
trap 'rm -f "$pr_list_file" "$page_file" "${_GH_API_HEADER_FILE:-}"' EXIT

base_query=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$base_target")
page=1
total=0
while true; do
  if ! batch=$(gh_get "${GH_API}/repos/${REPO}/pulls?state=open&base=${base_query}&per_page=100&page=${page}"); then
    fail "Could not fetch PR listing page ${page}; refusing to process an incomplete snapshot"
    exit 1
  fi
  if ! printf '%s' "$batch" | python3 scripts/parse-pr-branch-list.py > "$page_file"; then
    fail "Malformed PR listing page ${page}; refusing to process an incomplete snapshot"
    exit 1
  fi
  count=$(wc -l < "$page_file" | tr -d ' ')
  if [[ "$count" -eq 0 ]]; then
    break
  fi
  cat "$page_file" >> "$pr_list_file"
  total=$(( total + count ))
  [[ "$count" -lt 100 ]] && break
  (( page++ ))
done

# Detect duplicate PRs across pages before any candidate is processed.
if ! python3 - "$pr_list_file" <<'PY'
import json, sys
seen = set()
with open(sys.argv[1], encoding="utf-8") as stream:
    for line_number, line in enumerate(stream, 1):
        item = json.loads(line)
        number = item["number"]
        if number in seen:
            raise SystemExit(f"duplicate PR #{number} across listing pages (line {line_number})")
        seen.add(number)
PY
then
  fail "PR listing snapshot failed duplicate validation; refusing all writes"
  exit 1
fi

info "Validated complete snapshot: ${total} open PR(s) targeting '${base_target}'"
echo ""

# ── Counters ──────────────────────────────────────────────────────────────────
updated=0
conflicted=0
skipped=0
already_current=0

# ── Process each PR ───────────────────────────────────────────────────────────
while IFS= read -r pr_json; do
  [[ -z "$pr_json" ]] && continue
  mapfile -d '' -t pr_fields < <(python3 -c '
import json, sys
p = json.load(sys.stdin)
fields = [p["number"], p["head_ref"], p["head_sha"], p["base_ref"],
          "true" if p["draft"] else "false", p["title"]]
sys.stdout.buffer.write(b"\0".join(str(x).encode() for x in fields) + b"\0")
' <<< "$pr_json")
  number="${pr_fields[0]}"
  head_ref="${pr_fields[1]}"
  observed_head_sha="${pr_fields[2]}"
  observed_base_ref="${pr_fields[3]}"
  draft="${pr_fields[4]}"
  title="${pr_fields[5]}"

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
    warn "  Could not re-fetch PR detail — skipping without a write"
    (( skipped++ )) || true
    continue
  }
  mapfile -d '' -t detail_fields < <(python3 -c '
import json, sys
p = json.load(sys.stdin)
fields = [p.get("state", ""), p.get("head", {}).get("ref", ""),
          p.get("head", {}).get("sha", ""), p.get("base", {}).get("ref", ""),
          "true" if p.get("draft") else "false",
          p.get("mergeable_state", "unknown")]
sys.stdout.buffer.write(b"\0".join(str(x).encode() for x in fields) + b"\0")
' <<< "$pr_detail")
  current_state="${detail_fields[0]}"
  current_head_ref="${detail_fields[1]}"
  head_sha="${detail_fields[2]}"
  current_base_ref="${detail_fields[3]}"
  current_draft="${detail_fields[4]}"
  mergeable="${detail_fields[5]}"

  # Abort this candidate if it changed after the complete listing snapshot.
  if [[ "$current_state" != "open" || "$current_head_ref" != "$head_ref" ||
        "$head_sha" != "$observed_head_sha" || "$current_base_ref" != "$observed_base_ref" ||
        "$current_base_ref" != "$base_target" || "$current_draft" != "$draft" ]]; then
    warn "  PR snapshot changed since listing (state/ref/head/base/draft); skipping without a write"
    (( skipped++ )) || true
    continue
  fi
  if [[ "$SKIP_DRAFTS" == "true" && "$current_draft" == "true" ]]; then
    info "  → skipping (draft)"
    (( skipped++ )) || true
    continue
  fi

  info "  mergeable_state: ${mergeable}"

  case "$mergeable" in
    clean)
      info "  → already current and clean"
      (( already_current++ )) || true
      ;;
    behind)
      if [[ "$DRY_RUN" == "true" ]]; then
        dry "would ${UPDATE_METHOD}-update PR #${number} (${head_ref}) — behind base"
        (( updated++ )) || true
        continue
      fi
      info "  → applying ${UPDATE_METHOD} update (behind base)..."
      if [[ -z "$head_sha" ]]; then
        warn "  Could not determine PR head SHA — refusing a potentially stale update"
        (( conflicted++ )) || true
        continue
      fi
      if [[ "$UPDATE_METHOD" == "rebase" ]]; then
        # GitHub REST update-branch supports merge updates; gh CLI exposes the
        # supported --rebase operation. The CLI handles the branch rewrite.
        if gh pr update-branch "$number" --rebase --repo "$REPO"; then
          http_code="202"
        else
          http_code="500"
        fi
      else
        update_payload=$(EXPECTED_HEAD_SHA="$head_sha" python3 -c '
import json, os
print(json.dumps({"expected_head_sha": os.environ["EXPECTED_HEAD_SHA"]}))
')
        http_code=$(gh_put_status \
          "${GH_API}/repos/${REPO}/pulls/${number}/update-branch" \
          "$update_payload")
      fi
      if [[ "$http_code" == "202" || "$http_code" == "200" ]]; then
        ok "  PR #${number} updated (${head_ref} ← ${base_target})"
        (( updated++ )) || true
        pr_lifecycle_done "PR #${number}"
      else
        warn "  update-branch (${UPDATE_METHOD}) returned HTTP ${http_code} — flagging for review"
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
info " Update PR Branches complete"
info " Method:            ${UPDATE_METHOD}"
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
