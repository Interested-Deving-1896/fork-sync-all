#!/usr/bin/env bash
#
# scripts/auto-merge-prs.sh — merge open PRs once their required checks pass
#
# Three hybrid auto-detections run per PR:
#
#   SCOPE — which PRs to merge:
#     1. Label "auto-merge" present → always merge (explicit opt-in)
#     2. PR author is a known bot (github-actions[bot], SYNC_TOKEN owner,
#        any login ending in [bot]) → merge (automation output)
#     3. AUTO_MERGE_ALL=true env var → merge all open PRs
#     4. Default → skip (human PRs require explicit opt-in)
#
#   STRATEGY — how to merge:
#     1. Single commit on branch → rebase (linear, no merge commit)
#     2. Multiple commits, single author → squash (clean history)
#     3. Multiple commits, multiple authors → merge commit (preserves attribution)
#     Override with MERGE_STRATEGY=squash|rebase|merge
#
#   MECHANISM — how the merge is triggered:
#     1. Branch protection with required checks detected → GitHub native
#        auto-merge (gh pr merge --auto). GitHub queues the merge; zero
#        polling, fires exactly when checks pass.
#     2. No branch protection / no required checks → poll mergeable_state
#        until "clean", then merge directly. Falls back gracefully.
#     Override with MERGE_MECHANISM=native|poll
#
# Required env vars:
#   GH_TOKEN   — PAT with repo + pull-requests:write scopes
#   REPO       — owner/repo (e.g. Interested-Deving-1896/fork-sync-all)
#
# Optional env vars:
#   AUTO_MERGE_ALL    — "true" = merge all open PRs regardless of author/label
#   MERGE_STRATEGY    — squash | rebase | merge (blank = auto-detect)
#   MERGE_MECHANISM   — native | poll (blank = auto-detect)
#   PR_FILTER         — comma-separated PR numbers to process (blank = all open)
#   BASE_FILTER       — only process PRs targeting this base branch
#   DRY_RUN           — "true" = report without merging
#   DELETE_BRANCH     — "true" = delete head branch after merge (default: true)
#   SKIP_DRAFTS       — "true" = skip draft PRs (default: true)
#   MIN_QUOTA         — minimum REST quota required to start (default: 300)
#   POLL_TIMEOUT_MIN  — per-PR wait in poll mode (default: 5)
#   POLL_INTERVAL_SEC — seconds between poll attempts (default: 30)
#   MAX_RUN_DURATION_MIN — total processing budget, before job timeout (default: 35)

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${REPO:?REPO is required — owner/repo format}"

GH_API="https://api.github.com"
AUTO_MERGE_ALL="${AUTO_MERGE_ALL:-false}"
MERGE_STRATEGY="${MERGE_STRATEGY:-}"
MERGE_MECHANISM="${MERGE_MECHANISM:-}"
PR_FILTER="${PR_FILTER:-}"
BASE_FILTER="${BASE_FILTER:-}"
DRY_RUN="${DRY_RUN:-false}"
DELETE_BRANCH="${DELETE_BRANCH:-true}"
SKIP_DRAFTS="${SKIP_DRAFTS:-true}"
MIN_QUOTA="${MIN_QUOTA:-300}"
POLL_TIMEOUT_MIN="${POLL_TIMEOUT_MIN:-5}"
POLL_INTERVAL_SEC="${POLL_INTERVAL_SEC:-30}"
MAX_RUN_DURATION_MIN="${MAX_RUN_DURATION_MIN:-35}"

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/includes/gh-api.sh
source "${_SCRIPT_DIR}/includes/gh-api.sh"
# shellcheck source=scripts/includes/budget.sh
source "${_SCRIPT_DIR}/includes/budget.sh"
budget_init

info()  { echo "[auto-merge] $*" >&2; }
warn()  { echo "[auto-merge][warn] $*" >&2; }
dry()   { echo "[auto-merge][dry-run] $*" >&2; }
fail()  { echo "[auto-merge][fail] $*" >&2; }

merged=0
skipped=0
queued=0
failed=0

# ── Quota pre-flight ──────────────────────────────────────────────────────────
remaining=$(gh_get "${GH_API}/rate_limit" | \
  python3 -c "import sys,json; print(json.load(sys.stdin)['resources']['core']['remaining'])" \
  2>/dev/null || echo "0")
if (( remaining < MIN_QUOTA )); then
  warn "Quota too low (${remaining} < ${MIN_QUOTA}) — skipping."
  exit 0
fi
info "Quota: ${remaining} remaining"

# ── Detect SYNC_TOKEN owner (bot identity check) ──────────────────────────────
_token_owner=""
_token_owner=$(gh_get "${GH_API}/user" | \
  python3 -c "import sys,json; print(json.load(sys.stdin).get('login',''))" \
  2>/dev/null || true)
info "Token owner: ${_token_owner:-unknown}"

# ── Detect branch protection + required checks (mechanism detection) ──────────
_detect_mechanism() {
  local override="${MERGE_MECHANISM:-}"
  [[ -n "$override" ]] && { echo "$override"; return; }

  local default_branch
  default_branch=$(gh_get "${GH_API}/repos/${REPO}" | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('default_branch','main'))" \
    2>/dev/null || echo "main")

  local base="${BASE_FILTER:-$default_branch}"
  local protection protection_ok="false" has_required_checks="false"
  if protection=$(gh_get "${GH_API}/repos/${REPO}/branches/${base}/protection" 2>/dev/null); then
    if echo "$protection" | python3 -c "import sys,json; json.load(sys.stdin)" >/dev/null 2>&1; then
      protection_ok="true"
      has_required_checks=$(echo "$protection" | python3 -c 'import sys,json; d=json.load(sys.stdin); checks=d.get("required_status_checks",{}).get("contexts",[]); checks += [c.get("context","") for c in d.get("required_status_checks",{}).get("checks",[])]; print("true" if checks else "false")' 2>/dev/null || echo "false")
    fi
  fi

  # Classic branch-protection reads may be forbidden to this integration.
  # Inspect active repository rulesets too; never interpret an API error as
  # proof that required checks do not exist.
  local ruleset_list
  if ! ruleset_list=$(gh_get "${GH_API}/repos/${REPO}/rulesets?per_page=100" 2>/dev/null); then
    [[ "$protection_ok" == "true" && "$has_required_checks" == "true" ]] && { echo "native"; return; }
    echo "unsafe"
    return
  fi
  if ! echo "$ruleset_list" | python3 -c "import sys,json; assert isinstance(json.load(sys.stdin),list)" >/dev/null 2>&1; then
    echo "unsafe"
    return
  fi

  local ids id detail
  ids=$(echo "$ruleset_list" | python3 -c "
import sys,json
for r in json.load(sys.stdin):
    if r.get('target') == 'branch' and r.get('enforcement') == 'active':
        print(r.get('id',''))
")
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    if ! detail=$(gh_get "${GH_API}/repos/${REPO}/rulesets/${id}" 2>/dev/null); then
      echo "unsafe"
      return
    fi
    if ! echo "$detail" | python3 -c "import sys,json; json.load(sys.stdin)" >/dev/null 2>&1; then
      echo "unsafe"
      return
    fi
    if echo "$detail" | python3 -c 'import sys,json; d=json.load(sys.stdin); base=sys.argv[1]; conditions=d.get("conditions",{}).get("ref_name",{}); includes=conditions.get("include",[]); default_branch=sys.argv[2]; matches=(not includes or (base == default_branch and "~DEFAULT_BRANCH" in includes) or ("refs/heads/" + base) in includes or "*" in includes); checks=any(r.get("type")=="required_status_checks" and r.get("parameters",{}).get("required_status_checks") for r in d.get("rules",[])); print("true" if matches and checks else "false")' "$base" "$default_branch" 2>/dev/null | grep -qx true; then
      echo "native"
      return
    fi
  done <<< "$ids"

  if [[ "$protection_ok" == "true" ]]; then
    [[ "$has_required_checks" == "true" ]] && echo "native" || echo "poll"
  else
    # Unknown protection state is not equivalent to no required checks.
    echo "unsafe"
  fi
}

MECHANISM=$(_detect_mechanism)
info "Merge mechanism: ${MECHANISM} (${MERGE_MECHANISM:-auto-detected})"
if [[ "$MECHANISM" == "unsafe" ]]; then
  fail "Cannot determine required-check protection for base ${BASE_FILTER:-default branch}; refusing direct merges."
  exit 1
fi

# ── Helpers ───────────────────────────────────────────────────────────────────

# _is_bot_author LOGIN — returns 0 if the login looks like a bot
_is_bot_author() {
  local login="$1"
  # github-actions[bot], dependabot[bot], renovate[bot], any *[bot]
  [[ "$login" == *"[bot]" ]] && return 0
  # SYNC_TOKEN owner (the automation account running this repo)
  [[ -n "$_token_owner" && "$login" == "$_token_owner" ]] && return 0
  return 1
}

# _has_label PR_JSON LABEL — returns 0 if the PR has the given label
_has_label() {
  local pr_json="$1" label="$2"
  echo "$pr_json" | python3 -c "
import sys,json
labels=[l['name'] for l in json.load(sys.stdin).get('labels',[])]
exit(0 if '${label}' in labels else 1)
" 2>/dev/null
}

# _should_merge PR_JSON — returns 0 if this PR is in scope for auto-merge
_should_merge() {
  local pr_json="$1"
  local author
  author=$(echo "$pr_json" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('user',{}).get('login',''))" \
    2>/dev/null || echo "")

  # 1. Explicit label opt-in
  if _has_label "$pr_json" "auto-merge"; then
    info "  scope: auto-merge label present"
    return 0
  fi

  # 2. Bot-authored
  if _is_bot_author "$author"; then
    info "  scope: bot-authored (${author})"
    return 0
  fi

  # 3. Global flag
  if [[ "$AUTO_MERGE_ALL" == "true" ]]; then
    info "  scope: AUTO_MERGE_ALL=true"
    return 0
  fi

  info "  scope: skipping — human-authored PR without auto-merge label (${author})"
  return 1
}

# _detect_strategy PR_NUMBER — prints squash|rebase|merge
_detect_strategy() {
  local pr_number="$1"
  local override="${MERGE_STRATEGY:-}"
  [[ -n "$override" ]] && { echo "$override"; return; }

  local commits_json
  commits_json=$(gh_get "${GH_API}/repos/${REPO}/pulls/${pr_number}/commits?per_page=100" \
    2>/dev/null || echo "[]")

  local commit_count author_count
  commit_count=$(echo "$commits_json" | python3 -c \
    "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "1")
  author_count=$(echo "$commits_json" | python3 -c "
import sys,json
commits=json.load(sys.stdin)
authors=set(c.get('author',{}).get('login','') or c.get('commit',{}).get('author',{}).get('email','') for c in commits)
print(len(authors))
" 2>/dev/null || echo "1")

  if (( commit_count == 1 )); then
    echo "rebase"
  elif (( author_count == 1 )); then
    echo "squash"
  else
    echo "merge"
  fi
}

# _merge_native PR_NUMBER STRATEGY — enable GitHub native auto-merge
_merge_native() {
  local pr_number="$1" strategy="$2"
  local flag
  case "$strategy" in
    squash) flag="--squash" ;;
    rebase) flag="--rebase" ;;
    merge)  flag="--merge"  ;;
    *)      flag="--squash" ;;
  esac

  local delete_flag=""
  [[ "$DELETE_BRANCH" == "true" ]] && delete_flag="--delete-branch"

  GH_TOKEN="$GH_TOKEN" gh pr merge "$pr_number" \
    --repo "$REPO" \
    --auto \
    $flag \
    $delete_flag \
    2>&1
}

# _poll_deadline NOW PER_PR_TIMEOUT_MIN RUN_DEADLINE — return the earlier deadline.
_poll_deadline() {
  local now="$1" per_pr_timeout_min="$2" run_deadline="${3:-}"
  local per_pr_deadline=$(( now + per_pr_timeout_min * 60 ))
  if [[ -n "$run_deadline" ]] && (( run_deadline < per_pr_deadline )); then
    echo "$run_deadline"
  else
    echo "$per_pr_deadline"
  fi
}

# _poll_checks_state PR_NUMBER — return success only when commit status and every
# check-run page are green. API errors, malformed responses, and unknown states
# are never treated as success. Prints success|pending|failure|error.
_poll_checks_state() {
  local pr_number="$1" pr_detail head_sha status_json status_state
  pr_detail=$(gh_get "${GH_API}/repos/${REPO}/pulls/${pr_number}" 2>/dev/null) || { echo "error"; return 0; }
  head_sha=$(echo "$pr_detail" | python3 -c '
import json,sys
try:
 d=json.load(sys.stdin); sha=d.get("head",{}).get("sha","")
 print(sha if isinstance(sha,str) and len(sha)==40 and all(c in "0123456789abcdefABCDEF" for c in sha) else "")
except Exception: print("")
' 2>/dev/null)
  [[ -n "$head_sha" ]] || { echo "error"; return 0; }

  status_json=$(gh_get "${GH_API}/repos/${REPO}/commits/${head_sha}/status" 2>/dev/null) || { echo "error"; return 0; }
  status_state=$(echo "$status_json" | python3 -c '
import json,sys
try:
 d=json.load(sys.stdin); s=d.get("state"); statuses=d.get("statuses")
 if not isinstance(d,dict) or not isinstance(statuses,list) or s not in ("success","pending","failure","error"): raise ValueError()
 for item in statuses:
  if not isinstance(item,dict) or item.get("state") not in ("success","pending","failure","error"): raise ValueError()
  if item["state"] in ("failure","error"):
   print(f"failure:{len(statuses)}"); raise SystemExit
  if item["state"] == "pending":
   print(f"pending:{len(statuses)}"); raise SystemExit
 print(f"{s}:{len(statuses)}")
except Exception: print("invalid")
' 2>/dev/null)
  case "$status_state" in
    pending:*)
      # GitHub reports "pending" when there are no legacy commit statuses at
      # all. In that case, check-runs below are authoritative for CI state.
      [[ "${status_state#pending:}" != "0" ]] && { echo "pending"; return 0; }
      ;;
    failure:*|error:*) echo "failure"; return 0 ;;
    success:*) ;;
    *) echo "error"; return 0 ;;
  esac

  local page=1 check_page_state check_run_count=0 page_count
  while true; do
    local checks_json
    checks_json=$(gh_get "${GH_API}/repos/${REPO}/commits/${head_sha}/check-runs?per_page=100&page=${page}" 2>/dev/null) || { echo "error"; return 0; }
    check_page_state=$(echo "$checks_json" | python3 -c '
import json,sys
try:
 d=json.load(sys.stdin)
 if not isinstance(d,dict) or not isinstance(d.get("check_runs"),list): raise ValueError()
 runs=d["check_runs"]
 for run in runs:
  if not isinstance(run,dict): raise ValueError()
  conclusion=run.get("conclusion")
  if conclusion is None:
   print(("pending:more:" if len(runs)==100 else "pending:done:") + str(len(runs))); raise SystemExit
  if conclusion not in ("success","neutral","skipped"):
   print(("failure:more:" if len(runs)==100 else "failure:done:") + str(len(runs))); raise SystemExit
 print(("success:more:" if len(runs)==100 else "success:done:") + str(len(runs)))
except Exception: print("error:done:0")
' 2>/dev/null)
    case "$check_page_state" in
      error:*) echo "error"; return 0 ;;
      failure:*) echo "failure"; return 0 ;;
      pending:*) echo "pending"; return 0 ;;
      success:more:*)
        page_count="${check_page_state##*:}"
        check_run_count=$((check_run_count + page_count))
        (( page++ ))
        ;;
      success:done:*)
        page_count="${check_page_state##*:}"
        check_run_count=$((check_run_count + page_count))
        # A successful combined status with no legacy statuses is not enough
        # on its own: require at least one actual check run as evidence.
        if [[ "${status_state#*:}" == "0" && "$check_run_count" == "0" ]]; then
          echo "error"
        else
          # Return the exact head whose status and check-runs were verified.
          echo "success:${head_sha}"
        fi
        return 0
        ;;
      *) echo "error"; return 0 ;;
    esac
  done
}

# _merge_poll PR_NUMBER STRATEGY — poll mergeable_state then merge directly
_merge_poll() {
  local pr_number="$1" strategy="$2"
  local now deadline
  now=$(date +%s)
  deadline=$(_poll_deadline "$now" "$POLL_TIMEOUT_MIN" "${RUN_DEADLINE_EPOCH:-}")
  if (( deadline <= now )); then
    fail "  total run budget exhausted before polling PR #${pr_number}"
    return 1
  fi
  local attempts=0

  while (( $(date +%s) < deadline )); do
    (( attempts++ )) || true
    local pr_detail
    pr_detail=$(gh_get "${GH_API}/repos/${REPO}/pulls/${pr_number}" 2>/dev/null || echo "{}")
    local state
    state=$(echo "$pr_detail" | python3 -c \
      "import sys,json; print(json.load(sys.stdin).get('mergeable_state','unknown'))" \
      2>/dev/null || echo "unknown")

    info "  poll attempt ${attempts}: mergeable_state=${state}"

    case "$state" in
      clean)
        # Mergeability is not evidence that CI passed. Verify the PR head's
        # combined commit status and every paginated check-run before merging.
        local checks_state
        checks_state=$(_poll_checks_state "$pr_number")
        case "$checks_state" in
          success:*)
            verified_head_sha="${checks_state#success:}"
            if [[ ! "$verified_head_sha" =~ ^[0-9a-fA-F]{40}$ ]]; then
              fail "  check verification did not return a valid commit SHA; refusing direct merge"
              return 1
            fi
            info "  all reported checks are green for ${verified_head_sha} — merge now"
            ;;
          pending)
            info "  checks are still pending — waiting ${POLL_INTERVAL_SEC}s"
            sleep "$POLL_INTERVAL_SEC"
            continue
            ;;
          failure)
            fail "  PR #${pr_number} has a failed or non-success check; refusing direct merge"
            return 1
            ;;
          *)
            fail "  unable to verify all checks for PR #${pr_number}; refusing direct merge"
            return 1
            ;;
        esac
        local flag delete_flag=""
        case "$strategy" in
          squash) flag="--squash" ;;
          rebase) flag="--rebase" ;;
          merge)  flag="--merge"  ;;
          *)      flag="--squash" ;;
        esac
        [[ "$DELETE_BRANCH" == "true" ]] && delete_flag="--delete-branch"
        GH_TOKEN="$GH_TOKEN" gh pr merge "$pr_number" \
          --repo "$REPO" \
          $flag \
          --match-head-commit "$verified_head_sha" \
          $delete_flag \
          2>&1
        return $?
        ;;
      blocked|unstable)
        info "  checks still pending — waiting ${POLL_INTERVAL_SEC}s"
        sleep "$POLL_INTERVAL_SEC"
        ;;
      behind)
        info "  branch behind base — triggering update"
        gh_put_status "${GH_API}/repos/${REPO}/pulls/${pr_number}/update-branch" \
          '{"expected_head_sha":""}' >/dev/null 2>&1 || true
        sleep "$POLL_INTERVAL_SEC"
        ;;
      dirty|conflicting)
        fail "  PR #${pr_number} has conflicts — cannot auto-merge"
        return 1
        ;;
      unknown)
        info "  mergeability not yet computed — waiting"
        sleep "$POLL_INTERVAL_SEC"
        ;;
      *)
        info "  unexpected state '${state}' — waiting"
        sleep "$POLL_INTERVAL_SEC"
        ;;
    esac
  done

  if [[ -n "${RUN_DEADLINE_EPOCH:-}" ]] && (( $(date +%s) >= RUN_DEADLINE_EPOCH )); then
    fail "  total run budget (${MAX_RUN_DURATION_MIN}m) exhausted while waiting for PR #${pr_number}"
  else
    fail "  timed out after ${POLL_TIMEOUT_MIN}m waiting for checks on PR #${pr_number}"
  fi
  return 1
}

# ── Fetch open PRs ────────────────────────────────────────────────────────────
default_branch=$(gh_get "${GH_API}/repos/${REPO}" | \
  python3 -c "import sys,json; print(json.load(sys.stdin).get('default_branch','main'))" \
  2>/dev/null || echo "main")
base_target="${BASE_FILTER:-$default_branch}"

info "Fetching open PRs for ${REPO} (base: ${base_target})"

all_prs="[]"
page=1
while true; do
  budget_check 5 || break
  batch=$(gh_get "${GH_API}/repos/${REPO}/pulls?state=open&base=${base_target}&per_page=100&page=${page}") || break
  count=$(echo "$batch" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
  (( count == 0 )) && break
  all_prs=$(python3 -c "
import sys,json
a=json.loads('${all_prs}')
b=json.loads(sys.stdin.read())
print(json.dumps(a+b))
" <<< "$batch" 2>/dev/null || echo "$all_prs")
  (( count < 100 )) && break
  (( page++ ))
done

total=$(echo "$all_prs" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
info "Found ${total} open PR(s) targeting ${base_target}"

# Apply PR_FILTER if set
if [[ -n "$PR_FILTER" ]]; then
  filter_set=$(echo "$PR_FILTER" | tr ',' '\n' | tr -d ' ' | sort)
  all_prs=$(echo "$all_prs" | python3 -c "
import sys,json
prs=json.load(sys.stdin)
keep={n.strip() for n in '${PR_FILTER}'.split(',')}
print(json.dumps([p for p in prs if str(p['number']) in keep]))
")
  total=$(echo "$all_prs" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
  info "After PR_FILTER: ${total} PR(s)"
fi

# ── Process each PR ───────────────────────────────────────────────────────────
# Keep the job below its workflow timeout and leave time for summary/cleanup.
RUN_DEADLINE_EPOCH=$(( $(date +%s) + MAX_RUN_DURATION_MIN * 60 ))
while IFS= read -r pr_json; do
  [[ -z "$pr_json" ]] && continue
  if (( $(date +%s) >= RUN_DEADLINE_EPOCH )); then
    warn "Total run budget (${MAX_RUN_DURATION_MIN}m) exhausted; stopping before remaining PRs"
    break
  fi
  budget_check 10 || { warn "Budget exhausted — stopping early"; break; }

  number=$(echo "$pr_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['number'])" 2>/dev/null || continue)
  title=$(echo "$pr_json"  | python3 -c "import sys,json; print(json.load(sys.stdin)['title'])"  2>/dev/null || echo "")
  draft=$(echo "$pr_json"  | python3 -c "import sys,json; print(json.load(sys.stdin).get('draft',False))" 2>/dev/null || echo "False")
  head_ref=$(echo "$pr_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['head']['ref'])" 2>/dev/null || echo "")

  info "PR #${number}: ${title} (${head_ref})"

  # Skip drafts
  if [[ "$SKIP_DRAFTS" == "true" && "$draft" == "True" ]]; then
    info "  → skipping (draft)"
    (( skipped++ )) || true
    continue
  fi

  # Scope check
  if ! _should_merge "$pr_json"; then
    (( skipped++ )) || true
    continue
  fi

  # Strategy detection
  strategy=$(_detect_strategy "$number")
  info "  strategy: ${strategy} (${MERGE_STRATEGY:-auto-detected})"

  if [[ "$DRY_RUN" == "true" ]]; then
    dry "would merge PR #${number} via ${MECHANISM} (${strategy})"
    (( merged++ )) || true
    continue
  fi

  # Merge
  case "$MECHANISM" in
    native)
      info "  → enabling native auto-merge (${strategy})"
      if _merge_native "$number" "$strategy"; then
        info "  ✓ auto-merge enabled for PR #${number}"
        (( queued++ )) || true
      else
        fail "  ✗ failed to enable auto-merge for PR #${number}"
        (( failed++ )) || true
      fi
      ;;
    poll)
      info "  → polling for clean state then merging (${strategy})"
      if _merge_poll "$number" "$strategy"; then
        info "  ✓ merged PR #${number}"
        (( merged++ )) || true
      else
        fail "  ✗ failed to merge PR #${number}"
        (( failed++ )) || true
      fi
      ;;
  esac

done < <(echo "$all_prs" | python3 -c "
import sys,json
for pr in json.load(sys.stdin):
    print(json.dumps(pr))
")

# ── Summary ───────────────────────────────────────────────────────────────────
info "Done. merged=${merged} queued=${queued} skipped=${skipped} failed=${failed}"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## Auto-merge PRs"
    echo ""
    echo "| Result | Count |"
    echo "|---|---|"
    [[ "$MECHANISM" == "native" ]] && echo "| Queued for auto-merge | ${queued} |" || echo "| Merged directly | ${merged} |"
    echo "| Skipped (out of scope / draft) | ${skipped} |"
    echo "| Failed | ${failed} |"
    echo ""
    echo "Mechanism: \`${MECHANISM}\` | Strategy: \`${MERGE_STRATEGY:-auto-detected}\`"
  } >> "$GITHUB_STEP_SUMMARY"
fi

[[ "$failed" -gt 0 ]] && exit 1
exit 0
