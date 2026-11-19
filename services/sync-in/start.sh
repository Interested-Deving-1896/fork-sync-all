#!/usr/bin/env bash
#
# services/sync-in/start.sh — run a Sync-in server via Incus OCI
#
# Sync-in/server only ships Docker images (Docker Hub: syncin/server).
# This script uses Incus to launch the image as an application container,
# which does not require Docker to be installed.
#
# Requirements:
#   - incusd running (CAP_SYS_ADMIN + CAP_NET_ADMIN on the runner)
#   - Incus initialized (incus admin init --auto)
#
# Environment variables:
#   SYNC_IN_VERSION   — image tag to use (default: latest)
#   SYNC_IN_DATA_DIR  — host path for persistent data (default: ~/.local/share/sync-in)
#   SYNC_IN_PORT      — host port to expose (default: 3284)
#   SYNC_IN_ADMIN_TOKEN_FILE — path to store the admin token (default: SYNC_IN_DATA_DIR/.admin_token)
#
set -uo pipefail

SYNC_IN_VERSION="${SYNC_IN_VERSION:-latest}"
SYNC_IN_DATA_DIR="${SYNC_IN_DATA_DIR:-${HOME}/.local/share/sync-in}"
SYNC_IN_PORT="${SYNC_IN_PORT:-3284}"
SYNC_IN_ADMIN_TOKEN_FILE="${SYNC_IN_ADMIN_TOKEN_FILE:-${SYNC_IN_DATA_DIR}/.admin_token}"
CONTAINER_NAME="sync-in-server"
OCI_IMAGE="docker:syncin/server:${SYNC_IN_VERSION}"

info() { echo "[sync-in] $*" >&2; }
warn() { echo "[sync-in][warn] $*" >&2; }
die()  { echo "[sync-in][error] $*" >&2; exit 1; }

# ── Pre-flight: incusd must be running ────────────────────────────────────────
if ! incus info &>/dev/null; then
    die "incusd is not running. Start it with: gitpod automations service start incusd"
fi

# ── Pre-flight: Incus must be initialized ─────────────────────────────────────
if ! incus profile list &>/dev/null 2>&1; then
    info "Initializing Incus (first run)..."
    incus admin init --auto || die "incus admin init failed"
fi

# ── Data directory ────────────────────────────────────────────────────────────
mkdir -p "${SYNC_IN_DATA_DIR}"

# ── Remove stale container if present ────────────────────────────────────────
if incus list --format csv --columns n | grep -qx "${CONTAINER_NAME}"; then
    info "Removing stale container ${CONTAINER_NAME}..."
    incus stop "${CONTAINER_NAME}" --force 2>/dev/null || true
    incus delete "${CONTAINER_NAME}" --force 2>/dev/null || true
fi

# ── Launch via Incus OCI ──────────────────────────────────────────────────────
info "Launching ${OCI_IMAGE} as ${CONTAINER_NAME}..."
incus launch "${OCI_IMAGE}" "${CONTAINER_NAME}" \
    --config raw.idmap="both 1000 1000" \
    --device "sync-in-data,source=${SYNC_IN_DATA_DIR},path=/data,type=disk" \
    --device "sync-in-port,connect=tcp:127.0.0.1:${SYNC_IN_PORT},listen=tcp:0.0.0.0:${SYNC_IN_PORT},type=proxy" \
    || die "incus launch failed"

info "Container started. Waiting for health endpoint..."

# ── Wait for health check ─────────────────────────────────────────────────────
for i in $(seq 1 30); do
    if curl -sf "http://localhost:${SYNC_IN_PORT}/api/v1/health" &>/dev/null; then
        info "Sync-in server is ready on port ${SYNC_IN_PORT}"
        break
    fi
    sleep 2
done

if ! curl -sf "http://localhost:${SYNC_IN_PORT}/api/v1/health" &>/dev/null; then
    warn "Health check did not pass after 60s — check: incus logs ${CONTAINER_NAME}"
fi

# ── Admin token ───────────────────────────────────────────────────────────────
# Sync-in generates an admin token on first start, stored in /data inside the container.
# Extract it and cache locally for the sync-in.yml workflow.
if [[ ! -f "${SYNC_IN_ADMIN_TOKEN_FILE}" ]]; then
    _token=$(incus exec "${CONTAINER_NAME}" -- \
        cat /data/.admin_token 2>/dev/null || echo "")
    if [[ -n "$_token" ]]; then
        echo "$_token" > "${SYNC_IN_ADMIN_TOKEN_FILE}"
        chmod 600 "${SYNC_IN_ADMIN_TOKEN_FILE}"
        info "Admin token cached at ${SYNC_IN_ADMIN_TOKEN_FILE}"
    else
        warn "Could not read admin token from container — check /data/.admin_token inside ${CONTAINER_NAME}"
    fi
fi

info "Sync-in server running. URL: http://localhost:${SYNC_IN_PORT}"
info "Container: incus exec ${CONTAINER_NAME} -- bash"
info "Logs:      incus logs ${CONTAINER_NAME}"

# Keep the service alive by tailing container logs
exec incus logs "${CONTAINER_NAME}" --follow
