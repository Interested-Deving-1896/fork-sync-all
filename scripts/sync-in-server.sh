#!/usr/bin/env bash
#
# scripts/sync-in-server.sh — Sync-in server lifecycle management
#
# Manages a Sync-in server instance: health-check, deploy/update via Docker,
# and token rotation. Designed to run from GitHub Actions against a
# self-hosted runner or a remote host via SSH.
#
# ── Roles ─────────────────────────────────────────────────────────────────────
#
#   health   — check server reachability and version, report to step summary
#   deploy   — pull latest Sync-in Docker image and restart the container
#   update   — same as deploy (alias for clarity in workflow dispatch)
#   rotate   — rotate the server admin token and update the GitHub secret
#
# ── Required env vars ─────────────────────────────────────────────────────────
#
#   SYNC_IN_SERVER_URL   — base URL of the Sync-in instance (e.g. https://sync.myhost.com)
#   SYNC_IN_ADMIN_TOKEN  — admin API token for the Sync-in instance
#
# ── Optional env vars ─────────────────────────────────────────────────────────
#
#   ACTION              — health | deploy | update | rotate (default: health)
#   DOCKER_IMAGE        — Docker image to deploy (default: syncin/server:latest)
#   DOCKER_CONTAINER    — container name (default: sync-in)
#   DRY_RUN             — "true" = report without making changes
#   GH_TOKEN            — required for rotate action (updates GitHub secret)
#   GH_REPO             — repo to update secret on (default: $GITHUB_REPOSITORY)

set -uo pipefail

ACTION="${ACTION:-health}"
DOCKER_IMAGE="${DOCKER_IMAGE:-syncin/server:latest}"
DOCKER_CONTAINER="${DOCKER_CONTAINER:-sync-in}"
DRY_RUN="${DRY_RUN:-false}"

info() { echo "[sync-in-server] $*" >&2; }
warn() { echo "[sync-in-server][warn] $*" >&2; }
dry()  { echo "[sync-in-server][dry-run] $*" >&2; }

# ── health ────────────────────────────────────────────────────────────────────
_health() {
  : "${SYNC_IN_SERVER_URL:?SYNC_IN_SERVER_URL is required}"
  : "${SYNC_IN_ADMIN_TOKEN:?SYNC_IN_ADMIN_TOKEN is required}"

  info "Checking ${SYNC_IN_SERVER_URL} ..."

  local http_code version
  http_code=$(curl -sf -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${SYNC_IN_ADMIN_TOKEN}" \
    "${SYNC_IN_SERVER_URL}/api/v1/server/info" 2>/dev/null || echo "000")

  if [[ "$http_code" == "200" ]]; then
    version=$(curl -sf \
      -H "Authorization: Bearer ${SYNC_IN_ADMIN_TOKEN}" \
      "${SYNC_IN_SERVER_URL}/api/v1/server/info" 2>/dev/null | \
      python3 -c "import sys,json; print(json.load(sys.stdin).get('version','unknown'))" 2>/dev/null || echo "unknown")
    info "✓ Server healthy — version=${version} url=${SYNC_IN_SERVER_URL}"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
      echo "## Sync-in Server Health" >> "$GITHUB_STEP_SUMMARY"
      echo "- **Status**: ✅ Healthy" >> "$GITHUB_STEP_SUMMARY"
      echo "- **Version**: \`${version}\`" >> "$GITHUB_STEP_SUMMARY"
      echo "- **URL**: ${SYNC_IN_SERVER_URL}" >> "$GITHUB_STEP_SUMMARY"
    fi
    return 0
  else
    warn "✗ Server unreachable (HTTP ${http_code}) — ${SYNC_IN_SERVER_URL}"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
      echo "## Sync-in Server Health" >> "$GITHUB_STEP_SUMMARY"
      echo "- **Status**: ❌ Unreachable (HTTP ${http_code})" >> "$GITHUB_STEP_SUMMARY"
      echo "- **URL**: ${SYNC_IN_SERVER_URL}" >> "$GITHUB_STEP_SUMMARY"
    fi
    return 1
  fi
}

# ── deploy / update ───────────────────────────────────────────────────────────
_deploy() {
  info "Deploying ${DOCKER_IMAGE} as container '${DOCKER_CONTAINER}' ..."

  if [[ "$DRY_RUN" == "true" ]]; then
    dry "would: docker pull ${DOCKER_IMAGE}"
    dry "would: docker stop ${DOCKER_CONTAINER} && docker rm ${DOCKER_CONTAINER}"
    dry "would: docker run -d --name ${DOCKER_CONTAINER} --restart unless-stopped ${DOCKER_IMAGE}"
    return 0
  fi

  docker pull "${DOCKER_IMAGE}" || { warn "docker pull failed"; return 1; }

  # Stop and remove existing container (non-fatal if not running)
  docker stop "${DOCKER_CONTAINER}" 2>/dev/null || true
  docker rm   "${DOCKER_CONTAINER}" 2>/dev/null || true

  # Re-run with existing env file if present, otherwise bare
  local env_flag=""
  [[ -f "/etc/sync-in/env" ]] && env_flag="--env-file /etc/sync-in/env"

  # shellcheck disable=SC2086
  docker run -d \
    --name "${DOCKER_CONTAINER}" \
    --restart unless-stopped \
    -p 3000:3000 \
    $env_flag \
    "${DOCKER_IMAGE}" || { warn "docker run failed"; return 1; }

  info "✓ Container started — waiting 10s for readiness ..."
  sleep 10
  _health
}

# ── rotate ────────────────────────────────────────────────────────────────────
_rotate() {
  : "${SYNC_IN_SERVER_URL:?SYNC_IN_SERVER_URL is required}"
  : "${SYNC_IN_ADMIN_TOKEN:?SYNC_IN_ADMIN_TOKEN is required}"
  : "${GH_TOKEN:?GH_TOKEN is required for rotate action}"

  local repo="${GH_REPO:-${GITHUB_REPOSITORY:-}}"
  [[ -z "$repo" ]] && { warn "GH_REPO or GITHUB_REPOSITORY required for rotate"; return 1; }

  info "Rotating admin token for ${SYNC_IN_SERVER_URL} ..."

  if [[ "$DRY_RUN" == "true" ]]; then
    dry "would: POST ${SYNC_IN_SERVER_URL}/api/v1/auth/rotate-token"
    dry "would: update GitHub secret SYNC_IN_ADMIN_TOKEN on ${repo}"
    return 0
  fi

  local new_token
  new_token=$(curl -sf -X POST \
    -H "Authorization: Bearer ${SYNC_IN_ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    "${SYNC_IN_SERVER_URL}/api/v1/auth/rotate-token" 2>/dev/null | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || echo "")

  if [[ -z "$new_token" ]]; then
    warn "Token rotation failed — server did not return a new token"
    return 1
  fi

  # Update GitHub secret
  gh secret set SYNC_IN_ADMIN_TOKEN \
    --repo "$repo" \
    --body "$new_token" 2>/dev/null || { warn "Failed to update GitHub secret"; return 1; }

  info "✓ Token rotated and GitHub secret updated"
}

# ── dispatch ──────────────────────────────────────────────────────────────────
case "$ACTION" in
  health)         _health  ;;
  deploy|update)  _deploy  ;;
  rotate)         _rotate  ;;
  *)
    warn "Unknown ACTION '${ACTION}'. Use: health | deploy | update | rotate"
    exit 1
    ;;
esac
