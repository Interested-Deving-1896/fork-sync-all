#!/usr/bin/env bash
#
# critical-deploy-github.sh
#
# Org-agnostic GitHub critical deploy. Runs the same three-phase fast-lane
# against any GitHub org — OSP, OOC, or Interested-Deving-1896.
#
# Three composable phases:
#
#   Phase 1 — Commit + push (optional)
#     Commits COMMIT_FILES and pushes to TARGET_REPO on TARGET_ORG.
#     Use when a fix needs to land in a specific org repo immediately.
#
#   Phase 2 — Queue clear
#     Cancels all queued/in-progress workflow runs in TARGET_ORG/TARGET_REPO
#     that are older than STALE_QUEUE_MIN minutes or match CANCEL_WORKFLOWS.
#     Equivalent to the queue-manager aggressive clear.
#
#   Phase 3 — Priority dispatch
#     Dispatches WORKFLOWS (space-separated workflow filenames) in
#     TARGET_ORG/TARGET_REPO with WORKFLOW_INPUTS.
#
# Required env:
#   GH_TOKEN      — PAT with repo + workflow + admin:org scopes on TARGET_ORG
#   TARGET_ORG    — GitHub org to operate on (e.g. OpenOS-Project-OSP)
#   TARGET_REPO   — repo within TARGET_ORG (default: fork-sync-all)
#
# Optional env:
#   COMMIT_FILES      — space-separated file paths to stage and commit
#   COMMIT_MESSAGE    — commit message (default: "chore: critical deploy fix")
#   COMMIT_AUTHOR     — "Name <email>" (default: github-actions[bot])
#   CANCEL_WORKFLOWS  — space-separated workflow filenames to cancel (default: all)
#   STALE_QUEUE_MIN   — cancel runs queued longer than this (default: 10)
#   WORKFLOWS         — space-separated workflow filenames to dispatch
#   WORKFLOW_INPUTS   — JSON inputs for dispatched workflows (default: {})
#   WAIT_FOR_EACH     — "true" to wait for each dispatched workflow (default: false)
#   TIMEOUT_MIN       — wait timeout per workflow in minutes (default: 20)
#   DRY_RUN           — "true" to report without acting (default: false)
#   MIN_QUOTA         — minimum quota required to proceed (default: 200)

set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${TARGET_ORG:?TARGET_ORG is required}"

TARGET_REPO="${TARGET_REPO:-fork-sync-all}"
COMMIT_FILES="${COMMIT_FILES:-}"
COMMIT_MESSAGE="${COMMIT_MESSAGE:-chore: critical deploy fix [skip ci]}"
COMMIT_AUTHOR="${COMMIT_AUTHOR:-github-actions[bot] <github-actions[bot]@users.noreply.github.com>}"
CANCEL_WORKFLOWS="${CANCEL_WORKFLOWS:-}"
STALE_QUEUE_MIN="${STALE_QUEUE_MIN:-10}"
WORKFLOWS="${WORKFLOWS:-}"
WORKFLOW_INPUTS="${WORKFLOW_INPUTS:-{}}"
WAIT_FOR_EACH="${WAIT_FOR_EACH:-false}"
TIMEOUT_MIN="${TIMEOUT_MIN:-20}"
DRY_RUN="${DRY_RUN:-false}"
MIN_QUOTA="${MIN_QUOTA:-200}"

API="https://api.github.com"

# ── Logging ───────────────────────────────────────────────────────────────────

info() { echo "[critical-deploy:${TARGET_ORG}] $*" >&2; }
ok()   { echo "[critical-deploy:${TARGET_ORG}] ✅ $*" >&2; }
warn() { echo "[critical-deploy:${TARGET_ORG}] ⚠️  $*" >&2; }
dry()  { echo "[critical-deploy:${TARGET_ORG}] [dry-run] $*" >&2; }
fail() { echo "[critical-deploy:${TARGET_ORG}] ❌ $*" >&2; exit 1; }

# ── GitHub API helper ─────────────────────────────────────────────────────────

gh_api() {
  local method="${1:-GET}"
  local path="$2"
  shift 2
  curl -sf -X "$method" \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${API}${path}" "$@"
}

# ── Quota check ───────────────────────────────────────────────────────────────

info "Target: ${TARGET_ORG}/${TARGET_REPO}"

read -r remaining reset_at < <(gh_api GET "/rate_limit" \
  | python3 -c "
import sys,json,datetime
d=json.load(sys.stdin).get('resources',{}).get('core',{})
r=d.get('remaining',0)
ts=d.get('reset',0)
rt=(lambda dt: dt.strftime('%H:%M UTC') + ' / ' + dt.strftime('%I:%M %p UTC').lstrip('0') or '12:00 AM UTC')(datetime.datetime.fromtimestamp(ts,tz=datetime.timezone.utc)) if ts else 'unknown'
print(r, rt)
" 2>/dev/null || echo "0 unknown")

info "Quota: ${remaining} remaining (resets ${reset_at}, min: ${MIN_QUOTA})"

if [[ "${remaining}" -lt "${MIN_QUOTA}" ]]; then
  warn "Quota too low (${remaining} < ${MIN_QUOTA}) — workflow dispatch will fail."
  warn "Phase 1 (commit/push) will still work if COMMIT_FILES is set."
fi
echo "" >&2

# ── Phase 1: Commit + push ────────────────────────────────────────────────────

if [[ -n "$COMMIT_FILES" ]]; then
  info "── Phase 1: Commit + push to ${TARGET_ORG}/${TARGET_REPO}"

  # Get default branch
  default_branch=$(gh_api GET "/repos/${TARGET_ORG}/${TARGET_REPO}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('default_branch','main'))" 2>/dev/null || echo "main")
  info "  Default branch: ${default_branch}"

  # Get current tree SHA
  tree_sha=$(gh_api GET "/repos/${TARGET_ORG}/${TARGET_REPO}/git/refs/heads/${default_branch}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['object']['sha'])" 2>/dev/null || echo "")

  if [[ -z "$tree_sha" ]]; then
    warn "Could not get current tree SHA for ${TARGET_ORG}/${TARGET_REPO} — skipping commit phase"
  else
    # Build blobs for each file
    blobs=()
    for f in $COMMIT_FILES; do
      [[ -f "$f" ]] || { warn "  File not found: $f — skipping"; continue; }
      content_b64=$(base64 -w0 < "$f")
      blob_sha=$(gh_api POST "/repos/${TARGET_ORG}/${TARGET_REPO}/git/blobs" \
        -d "{\"content\":\"${content_b64}\",\"encoding\":\"base64\"}" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['sha'])" 2>/dev/null || echo "")
      [[ -n "$blob_sha" ]] && blobs+=("{\"path\":\"${f}\",\"mode\":\"100644\",\"type\":\"blob\",\"sha\":\"${blob_sha}\"}")
      info "  Staged: ${f} (blob=${blob_sha:0:8})"
    done

    if [[ "${#blobs[@]}" -gt 0 ]]; then
      tree_json=$(printf '%s,' "${blobs[@]}")
      tree_json="[${tree_json%,}]"

      # Create tree
      new_tree=$(gh_api POST "/repos/${TARGET_ORG}/${TARGET_REPO}/git/trees" \
        -d "{\"base_tree\":\"${tree_sha}\",\"tree\":${tree_json}}" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['sha'])" 2>/dev/null || echo "")

      if [[ -n "$new_tree" ]]; then
        # Create commit
        author_name="${COMMIT_AUTHOR%%<*}"; author_name="${author_name% }"
        author_email="${COMMIT_AUTHOR##*<}"; author_email="${author_email%>}"
        commit_payload=$(python3 -c "
import json
print(json.dumps({
  'message': '${COMMIT_MESSAGE}',
  'tree': '${new_tree}',
  'parents': ['${tree_sha}'],
  'author': {'name': '${author_name}', 'email': '${author_email}'}
}))")
        new_commit=$(gh_api POST "/repos/${TARGET_ORG}/${TARGET_REPO}/git/commits" \
          -d "$commit_payload" \
          | python3 -c "import sys,json; print(json.load(sys.stdin)['sha'])" 2>/dev/null || echo "")

        if [[ -n "$new_commit" ]]; then
          if [[ "$DRY_RUN" == "true" ]]; then
            dry "Would update ${default_branch} to ${new_commit:0:8}"
          else
            gh_api PATCH "/repos/${TARGET_ORG}/${TARGET_REPO}/git/refs/heads/${default_branch}" \
              -d "{\"sha\":\"${new_commit}\"}" > /dev/null
            ok "Pushed commit ${new_commit:0:8} to ${TARGET_ORG}/${TARGET_REPO}@${default_branch}"
          fi
        else
          warn "Failed to create commit"
        fi
      fi
    else
      info "  No files staged — skipping commit"
    fi
  fi
else
  info "── Phase 1: Skipped (COMMIT_FILES not set)"
fi
echo "" >&2

# ── Phase 2: Queue clear ──────────────────────────────────────────────────────

info "── Phase 2: Queue clear for ${TARGET_ORG}/${TARGET_REPO}"

# Fetch queued + in_progress runs
runs=$(gh_api GET "/repos/${TARGET_ORG}/${TARGET_REPO}/actions/runs?status=queued&per_page=50" \
  | python3 -c "import sys,json; [print(r['id'],r['name'],r['created_at']) for r in json.load(sys.stdin).get('workflow_runs',[])]" 2>/dev/null || true)
in_progress=$(gh_api GET "/repos/${TARGET_ORG}/${TARGET_REPO}/actions/runs?status=in_progress&per_page=50" \
  | python3 -c "import sys,json; [print(r['id'],r['name'],r['created_at']) for r in json.load(sys.stdin).get('workflow_runs',[])]" 2>/dev/null || true)

all_runs=$(printf "%s\n%s" "$runs" "$in_progress" | grep -v "^$" || true)
total=$(echo "$all_runs" | grep -c "." 2>/dev/null || echo 0)

if [[ "$total" -eq 0 ]]; then
  info "  No queued or in-progress runs found."
else
  info "  Found ${total} run(s) to evaluate..."
  cancelled=0
  skipped=0
  now_epoch=$(date +%s)

  while IFS=" " read -r run_id run_name run_created _rest; do
    [[ -z "$run_id" ]] && continue

    # Check age
    run_epoch=$(date -d "$run_created" +%s 2>/dev/null || echo 0)
    age_min=$(( (now_epoch - run_epoch) / 60 ))

    # Check if this workflow is in CANCEL_WORKFLOWS list (or cancel all if empty)
    should_cancel=false
    if [[ -z "$CANCEL_WORKFLOWS" ]]; then
      should_cancel=true
    else
      for wf in $CANCEL_WORKFLOWS; do
        [[ "$run_name" == *"$wf"* ]] && should_cancel=true && break
      done
    fi

    # Also cancel if stale
    [[ "$age_min" -ge "$STALE_QUEUE_MIN" ]] && should_cancel=true

    if [[ "$should_cancel" == "true" ]]; then
      if [[ "$DRY_RUN" == "true" ]]; then
        dry "Would cancel run ${run_id} (${run_name}, ${age_min}min old)"
      else
        http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
          -H "Authorization: token ${GH_TOKEN}" \
          -H "Accept: application/vnd.github+json" \
          "${API}/repos/${TARGET_ORG}/${TARGET_REPO}/actions/runs/${run_id}/cancel")
        if [[ "$http_code" == "202" ]]; then
          info "  Cancelled run ${run_id} (${run_name}, ${age_min}min old)"
          (( cancelled++ )) || true
        else
          warn "  Could not cancel run ${run_id} (HTTP ${http_code})"
        fi
      fi
    else
      (( skipped++ )) || true
    fi
  done <<< "$all_runs"

  ok "Queue clear: cancelled=${cancelled}, kept=${skipped}"
fi
echo "" >&2

# ── Phase 3: Priority dispatch ────────────────────────────────────────────────

if [[ -n "$WORKFLOWS" ]]; then
  info "── Phase 3: Dispatching workflows in ${TARGET_ORG}/${TARGET_REPO}"

  default_branch=$(gh_api GET "/repos/${TARGET_ORG}/${TARGET_REPO}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('default_branch','main'))" 2>/dev/null || echo "main")

  for wf in $WORKFLOWS; do
    info "  Dispatching: ${wf}"
    if [[ "$DRY_RUN" == "true" ]]; then
      dry "Would dispatch ${wf} on ${default_branch} with inputs: ${WORKFLOW_INPUTS}"
      continue
    fi

    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      "${API}/repos/${TARGET_ORG}/${TARGET_REPO}/actions/workflows/${wf}/dispatches" \
      -d "{\"ref\":\"${default_branch}\",\"inputs\":${WORKFLOW_INPUTS}}")

    if [[ "$http_code" == "204" ]]; then
      ok "Dispatched ${wf}"
    else
      warn "Failed to dispatch ${wf} (HTTP ${http_code})"
    fi

    # Brief pause between dispatches to avoid race conditions
    sleep 2
  done
else
  info "── Phase 3: Skipped (WORKFLOWS not set)"
fi
echo "" >&2

# ── Step Summary ──────────────────────────────────────────────────────────────

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  cat >> "$GITHUB_STEP_SUMMARY" << SUMMARY
## GitHub Critical Deploy — ${TARGET_ORG}

| Phase | Action | Status |
|---|---|---|
| 1 — Commit/push | ${COMMIT_FILES:-none} → ${TARGET_ORG}/${TARGET_REPO} | $([ -n "$COMMIT_FILES" ] && echo "✅ Run" || echo "⏭ Skipped") |
| 2 — Queue clear | Cancel queued/in-progress runs | ✅ Run |
| 3 — Dispatch | ${WORKFLOWS:-none} | $([ -n "$WORKFLOWS" ] && echo "✅ Run" || echo "⏭ Skipped") |
| Dry run | | ${DRY_RUN} |

**Org:** [${TARGET_ORG}](https://github.com/${TARGET_ORG})
**Repo:** [${TARGET_ORG}/${TARGET_REPO}](https://github.com/${TARGET_ORG}/${TARGET_REPO})
SUMMARY
fi

ok "GitHub critical deploy complete for ${TARGET_ORG}."
