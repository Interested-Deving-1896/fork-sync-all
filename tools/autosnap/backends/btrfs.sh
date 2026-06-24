#!/bin/sh
# backends/btrfs.sh — raw btrfs subvolume fallback backend
#
# Used automatically when the bdfs daemon is not running or not installed.
# Creates read-only btrfs subvolume snapshots directly via btrfs-progs.
#
# Snapshots are stored as siblings of @ on the top-level btrfs volume:
#   @autosnap-pre-<date>-<pm>
#   @autosnap-post-<date>-<pm>
#
# Retention is enforced by deleting the oldest snapshots when MAX_SNAPSHOTS
# is exceeded. No demote-to-DwarFS support (use the bdfs backend for that).

BTRFS_SNAP_PREFIX="@autosnap"
BTRFS_MP=""

_btrfs_check() {
    if ! command -v btrfs >/dev/null 2>&1; then
        log_error "btrfs-progs not found"
        return 1
    fi
    _fstype=$(findmnt -no FSTYPE / 2>/dev/null || echo unknown)
    if [ "$_fstype" != "btrfs" ]; then
        log_error "Root filesystem is not btrfs (detected: $_fstype)"
        return 1
    fi
}

_btrfs_mount_root() {
    _dev=$(findmnt -no SOURCE / 2>/dev/null)
    BTRFS_MP=$(mktemp -d /tmp/autosnap-btrfs-XXXXXX)
    if ! mount -o subvolid=5 "$_dev" "$BTRFS_MP" 2>/dev/null; then
        rmdir "$BTRFS_MP"
        log_error "Could not mount btrfs top-level volume from $_dev"
        return 1
    fi
    log_debug "Mounted btrfs root at $BTRFS_MP"
}

_btrfs_umount_root() {
    if [ -n "$BTRFS_MP" ] && mountpoint -q "$BTRFS_MP" 2>/dev/null; then
        umount "$BTRFS_MP"
        rmdir "$BTRFS_MP"
        BTRFS_MP=""
    fi
}

_btrfs_snap_name() {
    _type="$1"
    _pm="${2:-unknown}"
    _date=$(date '+%Y-%m-%dT%H:%M:%S')
    printf '%s-%s-%s-%s' "$BTRFS_SNAP_PREFIX" "$_type" "$_date" "$_pm"
}

backend_pre() {
    _desc="$1"
    _packages="$2"

    _btrfs_check    || return 1
    _btrfs_mount_root || return 1

    _name=$(_btrfs_snap_name "pre" "${AUTOSNAP_PM:-unknown}")
    _src="${BTRFS_MP}/@"
    _dst="${BTRFS_MP}/${_name}"

    if ! btrfs subvolume snapshot -r "$_src" "$_dst" >/dev/null; then
        _btrfs_umount_root
        log_error "btrfs snapshot failed: $_src -> $_dst"
        return 1
    fi

    # Sidecar metadata file
    mkdir -p "${BTRFS_MP}/.autosnap-meta"
    printf 'description=%s\npackages=%s\n' "$_desc" "$_packages" \
        > "${BTRFS_MP}/.autosnap-meta/${_name}.info"

    _btrfs_umount_root
    state_write "btrfs_pre_name" "$_name"
    log_info "btrfs fallback pre snapshot: $_name"
}

backend_post() {
    _desc="$1"

    _btrfs_check    || return 1
    _btrfs_mount_root || return 1

    _name=$(_btrfs_snap_name "post" "${AUTOSNAP_PM:-unknown}")
    _src="${BTRFS_MP}/@"
    _dst="${BTRFS_MP}/${_name}"

    if ! btrfs subvolume snapshot -r "$_src" "$_dst" >/dev/null; then
        _btrfs_umount_root
        log_error "btrfs post snapshot failed"
        return 1
    fi

    _pre_name=$(state_read "btrfs_pre_name")
    mkdir -p "${BTRFS_MP}/.autosnap-meta"
    printf 'description=%s\npre=%s\n' "$_desc" "$_pre_name" \
        > "${BTRFS_MP}/.autosnap-meta/${_name}.info"

    _btrfs_umount_root
    state_delete "btrfs_pre_name"
    log_info "btrfs fallback post snapshot: $_name (pre: ${_pre_name:-none})"

    _enforce_max_snapshots_btrfs
}

_enforce_max_snapshots_btrfs() {
    [ "${MAX_SNAPSHOTS:-5}" -le 0 ] && return

    _btrfs_mount_root || return

    _snaps=$(find "$BTRFS_MP" -maxdepth 1 \
        -name "${BTRFS_SNAP_PREFIX}-*" -type d | sort)
    _count=$(printf '%s\n' "$_snaps" | grep -c . || true)
    _excess=$(( _count - MAX_SNAPSHOTS ))

    if [ "$_excess" -gt 0 ]; then
        printf '%s\n' "$_snaps" | head -n "$_excess" | while read -r _snap; do
            btrfs subvolume delete "$_snap" >/dev/null \
                && rm -f "${BTRFS_MP}/.autosnap-meta/$(basename "$_snap").info" \
                && log_info "Deleted old btrfs snapshot: $(basename "$_snap")"
        done
    fi

    _btrfs_umount_root
}

backend_list() {
    _btrfs_check    || return 1
    _btrfs_mount_root || return 1

    printf '%-60s  %s\n' "NAME" "DESCRIPTION"
    find "$BTRFS_MP" -maxdepth 1 -name "${BTRFS_SNAP_PREFIX}-*" \
        -type d | sort | while read -r _snap; do
        _name=$(basename "$_snap")
        _info="${BTRFS_MP}/.autosnap-meta/${_name}.info"
        _desc="-"
        [ -f "$_info" ] && _desc=$(grep '^description=' "$_info" | cut -d= -f2-)
        printf '%-60s  %s\n' "$_name" "$_desc"
    done

    _btrfs_umount_root
}

backend_delete() {
    _name="$1"
    _btrfs_check    || return 1
    _btrfs_mount_root || return 1

    _target="${BTRFS_MP}/${_name}"
    if [ ! -d "$_target" ]; then
        log_error "Snapshot not found: $_name"
        _btrfs_umount_root
        return 1
    fi

    btrfs subvolume delete "$_target" >/dev/null \
        && rm -f "${BTRFS_MP}/.autosnap-meta/${_name}.info" \
        && log_info "Deleted: $_name"

    _btrfs_umount_root
}

backend_rollback() {
    _name="$1"
    _btrfs_check    || return 1
    _btrfs_mount_root || return 1

    _snap="${BTRFS_MP}/${_name}"
    _current="${BTRFS_MP}/@"
    _backup="${BTRFS_MP}/@autosnap-old-root-$(date '+%Y-%m-%dT%H:%M:%S')"

    if [ ! -d "$_snap" ]; then
        log_error "Snapshot not found: $_name"
        _btrfs_umount_root
        return 1
    fi

    mv "$_current" "$_backup" \
        && btrfs subvolume snapshot "$_snap" "$_current" >/dev/null \
        && log_info "Rolled back to $_name. Old root saved as $(basename "$_backup"). Reboot required."

    _btrfs_umount_root
}

backend_status() {
    _pre="${1:-}"
    _post="${2:-}"
    _btrfs_check    || return 1
    _btrfs_mount_root || return 1

    if [ -z "$_pre" ]; then
        backend_list
        _btrfs_umount_root
        return
    fi

    diff -rq --brief \
        "${BTRFS_MP}/${_pre}" \
        "${BTRFS_MP}/${_post:-@}" \
        2>/dev/null || true

    _btrfs_umount_root
}
