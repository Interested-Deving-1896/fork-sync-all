#!/bin/sh
# common.sh — shared helpers for autosnap (btrfs-dwarfs-framework edition)
#
# Backends: bdfs (primary), btrfs (fallback).
# All other backends (snapper, timeshift, LVM, ZFS, rsync) are not included
# in this build; autosnap here is scoped to the btrfs+DwarFS stack.

AUTOSNAP_VERSION="0.1.0"
AUTOSNAP_TAG="autosnap"
CONF_FILE="${AUTOSNAP_CONF:-/etc/autosnap.conf}"
STATE_DIR="${AUTOSNAP_STATE_DIR:-/var/lib/autosnap}"
LOG_TAG="autosnap"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log_info()  { logger -t "$LOG_TAG" -p user.info  "$*";           echo "$LOG_TAG: $*" >&2; }
log_warn()  { logger -t "$LOG_TAG" -p user.warn  "WARNING: $*";  echo "$LOG_TAG: WARNING: $*" >&2; }
log_error() { logger -t "$LOG_TAG" -p user.err   "ERROR: $*";    echo "$LOG_TAG: ERROR: $*" >&2; }
log_debug() { [ "${AUTOSNAP_DEBUG:-0}" = "1" ] && echo "$LOG_TAG: DEBUG: $*" >&2; }

# ---------------------------------------------------------------------------
# Config loading
# ---------------------------------------------------------------------------

# Defaults
BACKEND=""
MAX_SNAPSHOTS=5
RECORD_PACKAGES=true
SKIP_ENV_VAR=SKIP_AUTOSNAP
DESCRIPTION_TEMPLATE="autosnap: pre {action} on {date}"
BDFS_BIN=bdfs
BDFS_SOCKET=/run/bdfs/bdfs.sock
BDFS_PARTITION_UUID=""
BDFS_DEMOTE_ON_PRUNE=false
BDFS_DEMOTE_COMPRESSION=zstd

load_config() {
    if [ -f "$CONF_FILE" ]; then
        # shellcheck source=/dev/null
        . "$CONF_FILE"
        log_debug "Loaded config from $CONF_FILE"
    else
        log_debug "No config at $CONF_FILE, using defaults"
    fi
}

# ---------------------------------------------------------------------------
# Environment guards
# ---------------------------------------------------------------------------

should_skip() {
    if [ -n "$SKIP_ENV_VAR" ] && env | grep -q "^${SKIP_ENV_VAR}="; then
        log_info "Skipping: \$${SKIP_ENV_VAR} is set"
        return 0
    fi

    _fstype=$(findmnt -no FSTYPE / 2>/dev/null || echo unknown)
    if [ "$_fstype" = "overlay" ]; then
        log_info "Skipping: root is an overlay filesystem (Live CD?)"
        return 0
    fi

    return 1
}

# ---------------------------------------------------------------------------
# Backend auto-detection — bdfs first, raw btrfs as fallback
# ---------------------------------------------------------------------------

detect_backend() {
    if [ -n "$BACKEND" ]; then
        log_debug "Backend forced to '$BACKEND' by config"
        return
    fi

    # Primary: bdfs daemon reachable
    if command -v "$BDFS_BIN" >/dev/null 2>&1 && [ -S "$BDFS_SOCKET" ]; then
        BACKEND=bdfs
        log_info "Auto-detected backend: bdfs"
        return
    fi

    # Fallback: raw btrfs subvolume snapshots
    _fstype=$(findmnt -no FSTYPE / 2>/dev/null || echo unknown)
    if [ "$_fstype" = "btrfs" ] && command -v btrfs >/dev/null 2>&1; then
        log_warn "bdfs daemon not reachable — falling back to raw btrfs snapshots"
        log_warn "Start bdfs_daemon for full snapshot lifecycle management"
        BACKEND=btrfs
        log_info "Auto-detected backend: btrfs (fallback)"
        return
    fi

    log_error "No usable snapshot backend found."
    log_error "Either start bdfs_daemon or ensure the root filesystem is btrfs."
    exit 1
}

# ---------------------------------------------------------------------------
# State helpers
# ---------------------------------------------------------------------------

state_write() {
    _key="$1"; _val="$2"
    mkdir -p "$STATE_DIR"
    printf '%s' "$_val" > "${STATE_DIR}/${_key}"
}

state_read() {
    _key="$1"
    _file="${STATE_DIR}/${_key}"
    [ -f "$_file" ] && cat "$_file"
}

state_delete() {
    _key="$1"
    rm -f "${STATE_DIR}/${_key}"
}

# ---------------------------------------------------------------------------
# Description builder
# ---------------------------------------------------------------------------

build_description() {
    _action="${1:-unknown}"
    _date=$(date '+%Y-%m-%d %H:%M:%S')
    printf '%s' "$DESCRIPTION_TEMPLATE" \
        | sed -e "s/{action}/$_action/g" -e "s/{date}/$_date/g"
}

# ---------------------------------------------------------------------------
# Package list reader (stdin or AUTOSNAP_PACKAGES env var)
# ---------------------------------------------------------------------------

read_packages_from_stdin() {
    if [ -t 0 ]; then
        # No stdin pipe — fall back to env var (DNF, Zypper hooks)
        printf '%s' "${AUTOSNAP_PACKAGES:-}"
        return
    fi
    while IFS= read -r line; do
        _pkg=$(basename "$line" | sed 's/\.\(deb\|rpm\|pkg\.tar\.[a-z]*\)$//')
        printf '%s ' "$_pkg"
    done
    printf '\n'
}
