#!/usr/bin/env bash
#
# critical-deploy-stub.sh
#
# Stub template for adding a new platform to the critical deploy chain.
# Copy this file, rename it (e.g. critical-deploy-bitbucket.sh), then
# fill in every section marked TODO.
#
# This script is intentionally non-functional until the TODOs are resolved.
# It will exit 1 immediately if run as-is, so it is safe to commit.
#
# ── How to activate ──────────────────────────────────────────────────────────
#
#   1. Copy + rename:
#        cp scripts/critical-deploy-stub.sh scripts/critical-deploy-<platform>.sh
#        chmod +x scripts/critical-deploy-<platform>.sh
#
#   2. Fill in every TODO block below (search for "TODO").
#
#   3. Copy + rename the companion workflow stub:
#        cp .github/workflows/critical-deploy-stub.yml \
#           .github/workflows/critical-deploy-<platform>.yml
#      Then fill in the TODOs in that file too.
#
#   4. Wire the new workflow into critical-deploy-all.yml as a new job
#      (follow the pattern of deploy-gitlab — depends on deploy-ooc,
#      runs after the GitHub mirror jobs complete).
#
#   5. Register in config files:
#        config/workflow-sync.yml        — github_only section
#        config/workflow-priority-tiers.yml — tier 1
#        config/workflow-quota-costs.yml — with estimated costs
#
#   6. Run: python3 scripts/validate-workflow-guards.py
#
# ── Three-phase pattern ───────────────────────────────────────────────────────
#
#   Phase 1 — Push
#     Push the current HEAD (or specific files) to the target platform.
#     Git push never consumes CI minutes — works even at quota=0.
#
#   Phase 2 — Queue/pipeline clear
#     Cancel pending/running CI jobs on the target platform.
#     Frees the runner queue before dispatching new work.
#
#   Phase 3 — Trigger / dispatch
#     Trigger a specific pipeline, workflow, or job on the target platform.
#
# ── Required env (fill in below) ─────────────────────────────────────────────
#
#   TODO_PLATFORM_TOKEN  — PAT / app password / API key for the target platform
#   TODO_PROJECT_ID      — project/workspace/repo identifier on the platform
#   TODO_PROJECT_PATH    — human-readable path (for logging and summary links)
#   TODO_BASE_URL        — API base URL (e.g. https://api.bitbucket.org/2.0)
#   TODO_BRANCH          — branch to push to (default: main)
#
# ── Optional env ─────────────────────────────────────────────────────────────
#
#   PUSH_TO_PLATFORM     — "true" to push HEAD to the platform (default: false)
#   CLEAR_PIPELINES      — "true" to cancel pending/running jobs (default: false)
#   TRIGGER_PIPELINE     — "true" to trigger a new pipeline (default: false)
#   TRIGGER_VARS         — extra KEY=VALUE pairs for the triggered pipeline
#   DRY_RUN              — "true" to report without acting (default: false)

set -uo pipefail

# ── TODO: Guard — remove this block once the script is fully implemented ──────
echo "[critical-deploy-stub] This script is a stub and has not been implemented yet." >&2
echo "[critical-deploy-stub] Copy it, rename it, and fill in all TODO sections." >&2
echo "[critical-deploy-stub] See the header comment for step-by-step instructions." >&2
exit 1
# ── END GUARD ─────────────────────────────────────────────────────────────────

# ── TODO: Set your platform name (used in log prefixes and summary) ───────────
PLATFORM_NAME="TODO_PLATFORM_NAME"   # e.g. "Bitbucket", "Gitea", "Forgejo"

# ── TODO: Required env vars — update names to match your platform's secret ───
: "${TODO_PLATFORM_TOKEN:?TODO_PLATFORM_TOKEN is required — set the correct secret name}"

# ── TODO: Platform config — fill in defaults ──────────────────────────────────
TODO_BASE_URL="${TODO_BASE_URL:-https://TODO.example.com/api}"
TODO_PROJECT_ID="${TODO_PROJECT_ID:-TODO_PROJECT_ID}"
TODO_PROJECT_PATH="${TODO_PROJECT_PATH:-TODO_ORG/TODO_REPO}"
TODO_BRANCH="${TODO_BRANCH:-main}"

PUSH_TO_PLATFORM="${PUSH_TO_PLATFORM:-false}"
CLEAR_PIPELINES="${CLEAR_PIPELINES:-false}"
TRIGGER_PIPELINE="${TRIGGER_PIPELINE:-false}"
TRIGGER_VARS="${TRIGGER_VARS:-}"
DRY_RUN="${DRY_RUN:-false}"

# ── Logging ───────────────────────────────────────────────────────────────────

info() { echo "[critical-deploy-${PLATFORM_NAME,,}] $*" >&2; }
ok()   { echo "[critical-deploy-${PLATFORM_NAME,,}] ✅ $*" >&2; }
warn() { echo "[critical-deploy-${PLATFORM_NAME,,}] ⚠️  $*" >&2; }
dry()  { echo "[critical-deploy-${PLATFORM_NAME,,}] [dry-run] $*" >&2; }
fail() { echo "[critical-deploy-${PLATFORM_NAME,,}] ❌ $*" >&2; exit 1; }

# ── TODO: Platform API helper ─────────────────────────────────────────────────
# Replace the auth header and URL pattern to match your platform's API.
#
# Bitbucket example (Bearer token):
#   curl -sf -X "$method" \
#     -H "Authorization: Bearer ${TODO_PLATFORM_TOKEN}" \
#     -H "Content-Type: application/json" \
#     "${TODO_BASE_URL}${path}" "$@"
#
# Gitea / Forgejo / Codeberg example (token header):
#   curl -sf -X "$method" \
#     -H "Authorization: token ${TODO_PLATFORM_TOKEN}" \
#     -H "Content-Type: application/json" \
#     "${TODO_BASE_URL}${path}" "$@"
#
# Sourcehut example (OAuth2 Bearer):
#   curl -sf -X "$method" \
#     -H "Authorization: Bearer ${TODO_PLATFORM_TOKEN}" \
#     -H "Content-Type: application/json" \
#     "https://todo.sr.ht/api${path}" "$@"

platform_api() {
  local method="${1:-GET}"
  local path="$2"
  shift 2
  # TODO: replace with the correct auth header and base URL for your platform
  curl -sf -X "$method" \
    -H "Authorization: TODO_AUTH_SCHEME ${TODO_PLATFORM_TOKEN}" \
    -H "Content-Type: application/json" \
    "${TODO_BASE_URL}${path}" "$@"
}

# ── TODO: Token verification ──────────────────────────────────────────────────
# Call a lightweight authenticated endpoint to confirm the token is valid.
# Examples:
#   Bitbucket:  GET /2.0/user  → .display_name
#   Gitea:      GET /api/v1/user → .login
#   Forgejo:    GET /api/v1/user → .login
#   Sourcehut:  GET /api/user  → .name

info "Verifying ${PLATFORM_NAME} token..."
# TODO: replace path and jq/python expression with the correct endpoint
username=$(platform_api GET "/TODO_USER_ENDPOINT" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('TODO_USERNAME_FIELD','unknown'))" \
  2>/dev/null || echo "unknown")
if [[ "$username" == "unknown" ]]; then
  fail "Token is invalid or expired — cannot authenticate to ${PLATFORM_NAME} API"
fi
ok "Authenticated as: ${username}"
info "Target project: ${TODO_PROJECT_PATH} (id=${TODO_PROJECT_ID})"
echo "" >&2

# ── Phase 1: Git push ─────────────────────────────────────────────────────────

if [[ "$PUSH_TO_PLATFORM" == "true" ]]; then
  info "── Phase 1: Git push to ${PLATFORM_NAME}"

  local_sha=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
  info "  Local HEAD: ${local_sha}"

  # TODO: replace with the correct API call to fetch the remote branch HEAD SHA.
  # Bitbucket example:
  #   GET /2.0/repositories/{workspace}/{repo}/refs/branches/{branch}
  #   → .target.hash
  # Gitea/Forgejo example:
  #   GET /api/v1/repos/{owner}/{repo}/branches/{branch}
  #   → .commit.id
  remote_sha=$(platform_api GET "/TODO_BRANCH_ENDPOINT/${TODO_BRANCH}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('TODO_SHA_FIELD','unknown'))" \
    2>/dev/null || echo "unknown")
  info "  Remote HEAD: ${remote_sha}"

  if [[ "$local_sha" == "$remote_sha" ]]; then
    info "  Remote is already up to date — skipping push."
  elif [[ "$DRY_RUN" == "true" ]]; then
    dry "Would push ${local_sha} → ${TODO_BASE_URL%/api*}/${TODO_PROJECT_PATH}.git (${TODO_BRANCH})"
  else
    # TODO: replace with the correct authenticated remote URL for your platform.
    # Bitbucket:  https://x-token-auth:${TOKEN}@bitbucket.org/{workspace}/{repo}.git
    # Gitea:      https://x-access-token:${TOKEN}@gitea.example.com/{owner}/{repo}.git
    # Forgejo:    https://x-access-token:${TOKEN}@codeberg.org/{owner}/{repo}.git
    platform_remote="https://TODO_AUTH_USER:${TODO_PLATFORM_TOKEN}@TODO_HOST/${TODO_PROJECT_PATH}.git"

    if ! git remote get-url platform-critical &>/dev/null; then
      git remote add platform-critical "$platform_remote"
    else
      git remote set-url platform-critical "$platform_remote"
    fi

    if git push platform-critical "HEAD:refs/heads/${TODO_BRANCH}" --force-with-lease 2>&1 \
        | sed "s/${TODO_PLATFORM_TOKEN}/***TOKEN***/g"; then
      ok "Pushed to ${PLATFORM_NAME} ${TODO_BRANCH}"
    else
      warn "Push failed with --force-with-lease — retrying without lease..."
      git push platform-critical "HEAD:refs/heads/${TODO_BRANCH}" 2>&1 \
        | sed "s/${TODO_PLATFORM_TOKEN}/***TOKEN***/g" \
        || fail "Git push to ${PLATFORM_NAME} failed"
      ok "Pushed to ${PLATFORM_NAME} ${TODO_BRANCH}"
    fi

    git remote remove platform-critical 2>/dev/null || true
  fi
else
  info "── Phase 1: Skipped (PUSH_TO_PLATFORM=false)"
fi
echo "" >&2

# ── Phase 2: Cancel pending/running pipelines ─────────────────────────────────

if [[ "$CLEAR_PIPELINES" == "true" ]]; then
  info "── Phase 2: Cancelling pending/running pipelines on ${PLATFORM_NAME}"

  # TODO: replace with the correct API calls to list and cancel pipelines.
  #
  # Bitbucket Pipelines example:
  #   List:   GET /2.0/repositories/{ws}/{repo}/pipelines/?status=PENDING&status=IN_PROGRESS
  #   Cancel: POST /2.0/repositories/{ws}/{repo}/pipelines/{uuid}/stopPipeline
  #
  # Gitea Actions example:
  #   List:   GET /api/v1/repos/{owner}/{repo}/actions/runs?status=queued
  #           GET /api/v1/repos/{owner}/{repo}/actions/runs?status=in_progress
  #   Cancel: POST /api/v1/repos/{owner}/{repo}/actions/runs/{run_id}/cancel
  #
  # Forgejo Actions: same as Gitea
  #
  # Sourcehut builds example:
  #   List:   GET https://builds.sr.ht/api/jobs?filter=running
  #   Cancel: POST https://builds.sr.ht/api/jobs/{id}/cancel

  # TODO: implement pipeline listing
  pipeline_ids=""  # populate with newline-separated IDs
  count=$(echo "$pipeline_ids" | grep -c "." 2>/dev/null || echo 0)

  if [[ "$count" -eq 0 ]]; then
    info "  No pending or running pipelines found."
  elif [[ "$DRY_RUN" == "true" ]]; then
    dry "Would cancel ${count} pipeline(s)"
  else
    info "  Cancelling ${count} pipeline(s)..."
    cancelled=0
    while IFS= read -r pid; do
      [[ -z "$pid" ]] && continue
      # TODO: replace with the correct cancel endpoint for your platform
      http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        -H "Authorization: TODO_AUTH_SCHEME ${TODO_PLATFORM_TOKEN}" \
        "${TODO_BASE_URL}/TODO_CANCEL_ENDPOINT/${pid}/TODO_CANCEL_ACTION")
      if [[ "$http_code" =~ ^2 ]]; then
        info "  Cancelled pipeline ${pid}"
        (( cancelled++ )) || true
      else
        warn "  Could not cancel pipeline ${pid} (HTTP ${http_code})"
      fi
    done <<< "$pipeline_ids"
    ok "Cancelled ${cancelled}/${count} pipeline(s)"
  fi
else
  info "── Phase 2: Skipped (CLEAR_PIPELINES=false)"
fi
echo "" >&2

# ── Phase 3: Trigger pipeline ─────────────────────────────────────────────────

if [[ "$TRIGGER_PIPELINE" == "true" ]]; then
  info "── Phase 3: Triggering pipeline on ${PLATFORM_NAME}"

  # TODO: build the trigger payload for your platform.
  #
  # Bitbucket Pipelines example:
  #   POST /2.0/repositories/{ws}/{repo}/pipelines/
  #   body: {"target":{"ref_type":"branch","type":"pipeline_ref_target",
  #          "ref_name":"main"},"variables":[{"key":"K","value":"V"}]}
  #
  # Gitea / Forgejo Actions example:
  #   POST /api/v1/repos/{owner}/{repo}/actions/workflows/{workflow_id}/dispatches
  #   body: {"ref":"main","inputs":{}}
  #
  # Sourcehut builds example:
  #   POST https://builds.sr.ht/api/jobs
  #   body: {"manifest":"...","tags":["deploy"]}

  # TODO: replace with the correct trigger payload and endpoint
  payload="{}"  # TODO: build platform-specific payload

  if [[ "$DRY_RUN" == "true" ]]; then
    dry "Would trigger pipeline on ${TODO_BRANCH} with: ${payload}"
  else
    result=$(platform_api POST "/TODO_TRIGGER_ENDPOINT" -d "$payload" 2>/dev/null || echo "{}")
    # TODO: extract the pipeline ID / URL from the response
    pipeline_id=$(echo "$result" \
      | python3 -c "import sys,json; print(json.load(sys.stdin).get('TODO_ID_FIELD','unknown'))" \
      2>/dev/null || echo "unknown")
    pipeline_url=$(echo "$result" \
      | python3 -c "import sys,json; print(json.load(sys.stdin).get('TODO_URL_FIELD',''))" \
      2>/dev/null || echo "")

    if [[ "$pipeline_id" != "unknown" && -n "$pipeline_id" ]]; then
      ok "Pipeline triggered: id=${pipeline_id}"
      [[ -n "$pipeline_url" ]] && info "  URL: ${pipeline_url}"
    else
      warn "Pipeline trigger may have failed: ${result}"
    fi
  fi
else
  info "── Phase 3: Skipped (TRIGGER_PIPELINE=false)"
fi
echo "" >&2

# ── Step summary ──────────────────────────────────────────────────────────────

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  # TODO: update the project URL to match your platform
  cat >> "$GITHUB_STEP_SUMMARY" << SUMMARY_EOF
## ${PLATFORM_NAME} Critical Deploy

| Phase | Action | Status |
|---|---|---|
| 1 — Git push | Push HEAD to ${TODO_PROJECT_PATH} | $([ "$PUSH_TO_PLATFORM" = "true" ] && echo "✅ Run" || echo "⏭ Skipped") |
| 2 — Pipeline clear | Cancel pending/running pipelines | $([ "$CLEAR_PIPELINES" = "true" ] && echo "✅ Run" || echo "⏭ Skipped") |
| 3 — Trigger | Trigger pipeline | $([ "$TRIGGER_PIPELINE" = "true" ] && echo "✅ Run" || echo "⏭ Skipped") |
| Dry run | | ${DRY_RUN} |

**Project:** [${TODO_PROJECT_PATH}](https://TODO_HOST/${TODO_PROJECT_PATH})
SUMMARY_EOF
fi

ok "${PLATFORM_NAME} critical deploy complete."
