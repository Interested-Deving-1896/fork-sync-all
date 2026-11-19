#!/usr/bin/env bash
#
# critical-deploy-gitlab.sh
#
# GitLab equivalent of critical-deploy.sh. Fast-lane for deploying critical
# fixes to the openos-project/ops/fork-sync-all GitLab mirror when the system
# is in a degraded state (quota exhaustion, stale mirror, broken schedules).
#
# Three phases — all optional and composable:
#
#   Phase 1 — Git push to GitLab
#     Pushes the current HEAD directly to the GitLab mirror via HTTPS.
#     Git push never consumes GitLab compute minutes — works even at quota=0.
#     This is the primary mechanism for getting fixes to GitLab when the
#     GitHub→GitLab mirror sync is broken.
#
#   Phase 2 — Pipeline clear
#     Cancels all pending and running pipelines in the GitLab project.
#     Equivalent to the GitHub queue-manager aggressive clear.
#     Frees up the pipeline queue before triggering new work.
#
#   Phase 3 — Schedule management + pipeline trigger
#     Pause or resume GitLab schedules (stops the compute minute drain).
#     Optionally trigger a new pipeline with specific CADENCE/variables.
#
# Required env:
#   GITLAB_TOKEN    — GitLab PAT with api + write_repository scope
#   GL_PROJECT_ID   — GitLab project ID (default: 81413316 = ops/fork-sync-all)
#   GL_PROJECT_PATH — GitLab project path (default: openos-project/ops/fork-sync-all)
#
# Optional env:
#   PUSH_TO_GITLAB      — "true" to push current HEAD to GitLab (default: false)
#   GL_BRANCH           — branch to push to (default: main)
#   CLEAR_PIPELINES     — "true" to cancel all pending/running pipelines (default: false)
#   PAUSE_SCHEDULES     — "true" to pause all schedules (default: false)
#   RESUME_SCHEDULES    — "true" to resume all schedules (default: false)
#   TRIGGER_PIPELINE    — "true" to trigger a new pipeline (default: false)
#   TRIGGER_CADENCE     — CADENCE variable for triggered pipeline (default: "daily")
#   TRIGGER_VARS        — extra KEY=VALUE pairs (space-separated) for triggered pipeline
#   DRY_RUN             — "true" to report without acting (default: false)

set -uo pipefail

: "${GITLAB_TOKEN:?GITLAB_TOKEN is required}"

GL_API="https://gitlab.com/api/v4"
GL_PROJECT_ID="${GL_PROJECT_ID:-81413316}"
GL_PROJECT_PATH="${GL_PROJECT_PATH:-openos-project/ops/fork-sync-all}"
GL_BRANCH="${GL_BRANCH:-main}"

PUSH_TO_GITLAB="${PUSH_TO_GITLAB:-false}"
CLEAR_PIPELINES="${CLEAR_PIPELINES:-false}"
PAUSE_SCHEDULES="${PAUSE_SCHEDULES:-false}"
RESUME_SCHEDULES="${RESUME_SCHEDULES:-false}"
TRIGGER_PIPELINE="${TRIGGER_PIPELINE:-false}"
TRIGGER_CADENCE="${TRIGGER_CADENCE:-daily}"
TRIGGER_VARS="${TRIGGER_VARS:-}"
DRY_RUN="${DRY_RUN:-false}"

# ── Logging ───────────────────────────────────────────────────────────────────

info() { echo "[critical-deploy-gitlab] $*" >&2; }
ok()   { echo "[critical-deploy-gitlab] ✅ $*" >&2; }
warn() { echo "[critical-deploy-gitlab] ⚠️  $*" >&2; }
dry()  { echo "[critical-deploy-gitlab] [dry-run] $*" >&2; }
fail() { echo "[critical-deploy-gitlab] ❌ $*" >&2; exit 1; }

# ── GitLab API helper ─────────────────────────────────────────────────────────

gl_api() {
  local method="${1:-GET}"
  local path="$2"
  shift 2
  curl -sf -X "$method" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    -H "Content-Type: application/json" \
    "${GL_API}${path}" "$@"
}

# ── Verify token ──────────────────────────────────────────────────────────────

info "Verifying GitLab token..."
username=$(gl_api GET "/user" | python3 -c "import sys,json; print(json.load(sys.stdin).get('username','unknown'))" 2>/dev/null || echo "unknown")
if [[ "$username" == "unknown" ]]; then
  fail "GITLAB_TOKEN is invalid or expired — cannot authenticate to GitLab API"
fi
ok "Authenticated as: ${username}"
info "Target project: ${GL_PROJECT_PATH} (id=${GL_PROJECT_ID})"
echo "" >&2

# ── Phase 1: Git push to GitLab ───────────────────────────────────────────────

if [[ "$PUSH_TO_GITLAB" == "true" ]]; then
  info "── Phase 1: Git push to GitLab"

  local_sha=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
  info "  Local HEAD: ${local_sha}"

  # Check what GitLab currently has
  remote_sha=$(gl_api GET "/projects/${GL_PROJECT_ID}/repository/branches/${GL_BRANCH}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('commit',{}).get('id','unknown'))" 2>/dev/null || echo "unknown")
  info "  GitLab HEAD: ${remote_sha}"

  if [[ "$local_sha" == "$remote_sha" ]]; then
    info "  GitLab is already up to date — skipping push."
  elif [[ "$DRY_RUN" == "true" ]]; then
    dry "Would push ${local_sha} → gitlab.com/${GL_PROJECT_PATH}.git (${GL_BRANCH})"
  else
    info "  Pushing to gitlab.com/${GL_PROJECT_PATH}.git..."
    gl_remote="https://oauth2:${GITLAB_TOKEN}@gitlab.com/${GL_PROJECT_PATH}.git"

    # Add remote if not present
    if ! git remote get-url gitlab-critical &>/dev/null; then
      git remote add gitlab-critical "$gl_remote"
    else
      git remote set-url gitlab-critical "$gl_remote"
    fi

    if git push gitlab-critical "HEAD:refs/heads/${GL_BRANCH}" --force-with-lease 2>&1 \
        | sed "s/${GITLAB_TOKEN}/***TOKEN***/g"; then
      ok "Pushed to GitLab ${GL_BRANCH}"
    else
      warn "Git push failed — GitLab may have branch protection. Trying without --force-with-lease..."
      git push gitlab-critical "HEAD:refs/heads/${GL_BRANCH}" 2>&1 \
        | sed "s/${GITLAB_TOKEN}/***TOKEN***/g" \
        || fail "Git push to GitLab failed"
      ok "Pushed to GitLab ${GL_BRANCH}"
    fi

    # Clean up remote URL (don't leave token in git config)
    git remote remove gitlab-critical 2>/dev/null || true
  fi
else
  info "── Phase 1: Skipped (PUSH_TO_GITLAB=false)"
fi
echo "" >&2

# ── Phase 2: Cancel pending/running pipelines ─────────────────────────────────

if [[ "$CLEAR_PIPELINES" == "true" ]]; then
  info "── Phase 2: Cancelling pending/running pipelines"

  # Fetch pending + running pipelines
  pipelines=$(gl_api GET "/projects/${GL_PROJECT_ID}/pipelines?status=pending&per_page=50" \
    | python3 -c "import sys,json; [print(p['id']) for p in json.load(sys.stdin)]" 2>/dev/null || true)
  running=$(gl_api GET "/projects/${GL_PROJECT_ID}/pipelines?status=running&per_page=50" \
    | python3 -c "import sys,json; [print(p['id']) for p in json.load(sys.stdin)]" 2>/dev/null || true)

  all_pipelines=$(printf "%s\n%s" "$pipelines" "$running" | grep -v "^$" || true)
  count=$(echo "$all_pipelines" | grep -c "." || echo 0)

  if [[ "$count" -eq 0 ]]; then
    info "  No pending or running pipelines found."
  elif [[ "$DRY_RUN" == "true" ]]; then
    dry "Would cancel ${count} pipeline(s): $(echo "$all_pipelines" | tr '\n' ' ')"
  else
    info "  Cancelling ${count} pipeline(s)..."
    cancelled=0
    while IFS= read -r pid; do
      [[ -z "$pid" ]] && continue
      http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        "${GL_API}/projects/${GL_PROJECT_ID}/pipelines/${pid}/cancel")
      if [[ "$http_code" == "200" ]]; then
        info "  Cancelled pipeline ${pid}"
        (( cancelled++ )) || true
      else
        warn "  Could not cancel pipeline ${pid} (HTTP ${http_code})"
      fi
    done <<< "$all_pipelines"
    ok "Cancelled ${cancelled}/${count} pipeline(s)"
  fi
else
  info "── Phase 2: Skipped (CLEAR_PIPELINES=false)"
fi
echo "" >&2

# ── Phase 3a: Schedule management ────────────────────────────────────────────

if [[ "$PAUSE_SCHEDULES" == "true" || "$RESUME_SCHEDULES" == "true" ]]; then
  info "── Phase 3a: Schedule management"

  schedules=$(gl_api GET "/projects/${GL_PROJECT_ID}/pipeline_schedules?per_page=50" \
    | python3 -c "
import sys,json
for s in json.load(sys.stdin):
    print(s['id'], s['active'], s['description'])
" 2>/dev/null || true)

  if [[ -z "$schedules" ]]; then
    info "  No schedules found."
  else
    info "  Current schedules:"
    while IFS=" " read -r sid sactive sdesc; do
      info "    id=${sid} active=${sactive} — ${sdesc}"
    done <<< "$schedules"

    if [[ "$PAUSE_SCHEDULES" == "true" ]]; then
      action="pause"; active_val="false"
    else
      action="resume"; active_val="true"
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
      dry "Would ${action} all schedules"
    else
      while IFS=" " read -r sid _rest; do
        [[ -z "$sid" ]] && continue
        http_code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
          -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
          -H "Content-Type: application/json" \
          "${GL_API}/projects/${GL_PROJECT_ID}/pipeline_schedules/${sid}" \
          -d "{\"active\": ${active_val}}")
        if [[ "$http_code" == "200" ]]; then
          info "  ${action^}d schedule ${sid}"
        else
          warn "  Could not ${action} schedule ${sid} (HTTP ${http_code})"
        fi
      done <<< "$schedules"
      ok "All schedules ${action}d"
    fi
  fi
else
  info "── Phase 3a: Skipped (PAUSE_SCHEDULES=false, RESUME_SCHEDULES=false)"
fi
echo "" >&2

# ── Phase 3b: Trigger pipeline ────────────────────────────────────────────────

if [[ "$TRIGGER_PIPELINE" == "true" ]]; then
  info "── Phase 3b: Triggering pipeline (CADENCE=${TRIGGER_CADENCE})"

  # Build variables JSON
  vars_json="[{\"key\":\"CADENCE\",\"value\":\"${TRIGGER_CADENCE}\",\"variable_type\":\"env_var\"}"
  for kv in $TRIGGER_VARS; do
    key="${kv%%=*}"
    val="${kv#*=}"
    vars_json+=",{\"key\":\"${key}\",\"value\":\"${val}\",\"variable_type\":\"env_var\"}"
  done
  vars_json+="]"

  payload="{\"ref\":\"${GL_BRANCH}\",\"variables\":${vars_json}}"

  if [[ "$DRY_RUN" == "true" ]]; then
    dry "Would trigger pipeline on ${GL_BRANCH} with: ${payload}"
  else
    result=$(gl_api POST "/projects/${GL_PROJECT_ID}/pipeline" -d "$payload" 2>/dev/null || echo "{}")
    pipeline_id=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id','unknown'))" 2>/dev/null || echo "unknown")
    pipeline_url=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('web_url',''))" 2>/dev/null || echo "")

    if [[ "$pipeline_id" != "unknown" && "$pipeline_id" != "" ]]; then
      ok "Pipeline triggered: id=${pipeline_id}"
      [[ -n "$pipeline_url" ]] && info "  URL: ${pipeline_url}"
    else
      warn "Pipeline trigger may have failed: ${result}"
    fi
  fi
else
  info "── Phase 3b: Skipped (TRIGGER_PIPELINE=false)"
fi
echo "" >&2

# ── Step Summary ──────────────────────────────────────────────────────────────

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  cat >> "$GITHUB_STEP_SUMMARY" << SUMMARY
## GitLab Critical Deploy

| Phase | Action | Status |
|---|---|---|
| 1 — Git push | Push HEAD to gitlab.com/${GL_PROJECT_PATH} | $([ "$PUSH_TO_GITLAB" = "true" ] && echo "✅ Run" || echo "⏭ Skipped") |
| 2 — Pipeline clear | Cancel pending/running pipelines | $([ "$CLEAR_PIPELINES" = "true" ] && echo "✅ Run" || echo "⏭ Skipped") |
| 3a — Schedules | $([ "$PAUSE_SCHEDULES" = "true" ] && echo "Paused all schedules" || ([ "$RESUME_SCHEDULES" = "true" ] && echo "Resumed all schedules" || echo "No change")) | $([ "$PAUSE_SCHEDULES" = "true" ] || [ "$RESUME_SCHEDULES" = "true" ] && echo "✅ Run" || echo "⏭ Skipped") |
| 3b — Trigger | Trigger pipeline (CADENCE=${TRIGGER_CADENCE}) | $([ "$TRIGGER_PIPELINE" = "true" ] && echo "✅ Run" || echo "⏭ Skipped") |
| Dry run | | ${DRY_RUN} |

**Project:** [${GL_PROJECT_PATH}](https://gitlab.com/${GL_PROJECT_PATH})
SUMMARY
fi

ok "GitLab critical deploy complete."
