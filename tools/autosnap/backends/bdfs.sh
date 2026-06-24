#!/bin/sh
# backends/bdfs.sh — bdfs backend for autosnap
#
# Primary backend. Delegates snapshot creation to the bdfs daemon via the
# `bdfs snapshot` CLI, which routes through the daemon worker pool and
# integrates with bdfs snapshot prune and demote-first archival.
#
# Requires: bdfs daemon running, BDFS_PARTITION_UUID set in config or
#           auto-detected from the root btrfs mountpoint.
#
# Pre/post pairs are named:
#   autosnap-pre-<date>-<pm>
#   autosnap-post-<date>-<pm>
#
# Retention is enforced via `bdfs snapshot prune` so that pruned snapshots
# can optionally be demoted to DwarFS archives before deletion.

BDFS_BIN="${BDFS_BIN:-bdfs}"
BDFS_SOCKET="${BDFS_SOCKET:-/run/bdfs/bdfs.sock}"

_bdfs_check() {
    if ! command -v "$BDFS_BIN" >/dev/null 2>&1; then
        log_error "bdfs not found (install btrfs-dwarfs-framework)"
        return 1
    fi
    if [ ! -S "$BDFS_SOCKET" ]; then
        log_error "bdfs daemon socket not found at $BDFS_SOCKET — is bdfs_daemon running?"
        return 1
    fi
}

# Auto-detect the partition UUID.
#
# If BDFS_PARTITION_UUID is set in config, use it directly.
# Otherwise query `bdfs partition list --json`:
#   - exactly one partition → use it automatically
#   - zero partitions       → error: nothing to snapshot
#   - multiple partitions   → error: ambiguous; require explicit config
#
# The JSON output is one object per line with a "uuid" field, e.g.:
#   {"uuid":"xxxxxxxx-...","mount":"/","label":"root"}
_bdfs_detect_partition() {
    if [ -n "$BDFS_PARTITION_UUID" ]; then
        log_debug "BDFS_PARTITION_UUID set to '$BDFS_PARTITION_UUID' by config"
        return 0
    fi

    _json=$("$BDFS_BIN" partition list --json 2>/dev/null) || {
        log_error "bdfs partition list failed — is bdfs_daemon running?"
        return 1
    }

    # Extract all UUIDs (one per line)
    _uuids=$(printf '%s\n' "$_json" \
        | grep -o '"uuid":"[^"]*"' \
        | grep -o '[0-9a-f-]\{36\}')

    _count=$(printf '%s\n' "$_uuids" | grep -c . 2>/dev/null || echo 0)

    case "$_count" in
        0)
            log_error "No bdfs partitions found. Register a partition with 'bdfs partition add' first."
            return 1
            ;;
        1)
            BDFS_PARTITION_UUID=$(printf '%s\n' "$_uuids" | head -1)
            log_info "Auto-detected single bdfs partition: $BDFS_PARTITION_UUID"
            ;;
        *)
            log_error "Multiple bdfs partitions found ($_count). Set BDFS_PARTITION_UUID in /etc/autosnap.conf."
            log_error "Available partitions:"
            printf '%s\n' "$_uuids" | while read -r _u; do
                log_error "  $_u"
            done
            return 1
            ;;
    esac
}

_bdfs_snap_name() {
    _type="$1"   # pre | post
    _pm="${2:-unknown}"
    _date=$(date '+%Y-%m-%dT%H:%M:%S')
    printf 'autosnap-%s-%s-%s' "$_type" "$_date" "$_pm"
}

backend_pre() {
    _desc="$1"
    _packages="$2"

    _bdfs_check        || return 1
    _bdfs_detect_partition || return 1

    _name=$(_bdfs_snap_name "pre" "${AUTOSNAP_PM:-unknown}")

    # bdfs snapshot --partition <uuid> --btrfs-mount <path> --name <name>
    # We snapshot the root btrfs mount; bdfs tracks it in the partition registry.
    _btrfs_mount=$(findmnt -no TARGET -t btrfs / 2>/dev/null || echo "/")

    if ! "$BDFS_BIN" snapshot \
            --partition "$BDFS_PARTITION_UUID" \
            --btrfs-mount "$_btrfs_mount" \
            --name "$_name" \
            --readonly 2>/dev/null; then
        log_error "bdfs snapshot pre failed"
        return 1
    fi

    state_write "bdfs_pre_name" "$_name"
    state_write "bdfs_btrfs_mount" "$_btrfs_mount"

    # Record package list as a sidecar in the state dir (bdfs has no userdata field)
    if [ "$RECORD_PACKAGES" = "true" ] && [ -n "$_packages" ]; then
        state_write "bdfs_pre_packages" "$_packages"
    fi

    log_info "bdfs pre snapshot: $_name"
}

backend_post() {
    _desc="$1"

    _bdfs_check        || return 1
    _bdfs_detect_partition || return 1

    _name=$(_bdfs_snap_name "post" "${AUTOSNAP_PM:-unknown}")
    _btrfs_mount=$(state_read "bdfs_btrfs_mount")
    _btrfs_mount="${_btrfs_mount:-/}"

    if ! "$BDFS_BIN" snapshot \
            --partition "$BDFS_PARTITION_UUID" \
            --btrfs-mount "$_btrfs_mount" \
            --name "$_name" \
            --readonly 2>/dev/null; then
        log_error "bdfs snapshot post failed"
        return 1
    fi

    _pre_name=$(state_read "bdfs_pre_name")
    state_delete "bdfs_pre_name"
    state_delete "bdfs_btrfs_mount"
    state_delete "bdfs_pre_packages"

    log_info "bdfs post snapshot: $_name (pre: ${_pre_name:-none})"

    _enforce_max_snapshots_bdfs "$_btrfs_mount"
}

_enforce_max_snapshots_bdfs() {
    _mount="${1:-/}"
    [ "${MAX_SNAPSHOTS:-5}" -le 0 ] && return

    # Check whether this bdfs build supports --pattern in snapshot prune.
    # If not, fall back to pruning without a pattern filter (prunes all
    # snapshots under the mount, not just autosnap ones — warn the user).
    _prune_help=$("$BDFS_BIN" snapshot prune --help 2>&1 || true)
    _pattern_flag=""
    if printf '%s' "$_prune_help" | grep -q -- '--pattern'; then
        _pattern_flag="--pattern autosnap-*"
    else
        log_warn "bdfs snapshot prune --pattern not supported in this build; pruning all snapshots under $_mount"
    fi

    _demote_flag=""
    if [ "${BDFS_DEMOTE_ON_PRUNE:-false}" = "true" ]; then
        _demote_flag="--demote-first --compression ${BDFS_DEMOTE_COMPRESSION:-zstd}"
    fi

    # shellcheck disable=SC2086
    if "$BDFS_BIN" snapshot prune \
            --partition "$BDFS_PARTITION_UUID" \
            --btrfs-mount "$_mount" \
            --keep "$MAX_SNAPSHOTS" \
            $_pattern_flag \
            $_demote_flag 2>/dev/null; then
        log_info "bdfs snapshot prune: kept $MAX_SNAPSHOTS snapshots under $_mount"
    else
        log_warn "bdfs snapshot prune failed — snapshots may accumulate until pruned manually"
    fi
}

backend_list() {
    _bdfs_check || return 1
    # bdfs status shows active mounts; for snapshot listing use btrfs subvolume list
    _btrfs_mount=$(findmnt -no TARGET -t btrfs / 2>/dev/null || echo "/")
    btrfs subvolume list -o "$_btrfs_mount" 2>/dev/null \
        | grep "autosnap-" \
        || echo "(no autosnap snapshots found)"
}

backend_delete() {
    _name="$1"
    _bdfs_check || return 1
    _btrfs_mount=$(findmnt -no TARGET -t btrfs / 2>/dev/null || echo "/")
    _path="${_btrfs_mount}/${_name}"

    btrfs subvolume delete "$_path" 2>/dev/null \
        && log_info "Deleted bdfs/btrfs snapshot: $_name"
}

backend_rollback() {
    _name="$1"
    _bdfs_check || return 1

    log_warn "Rolling back to snapshot '$_name'."
    log_warn "This replaces the current @ subvolume. A reboot is required."

    _btrfs_mount=$(findmnt -no TARGET -t btrfs / 2>/dev/null || echo "/")
    _snap="${_btrfs_mount}/${_name}"
    _current="${_btrfs_mount}/@"
    _backup="${_btrfs_mount}/@autosnap-rollback-backup-$(date '+%Y%m%dT%H%M%S')"

    if [ ! -d "$_snap" ]; then
        log_error "Snapshot not found: $_snap"
        return 1
    fi

    mv "$_current" "$_backup" \
        && btrfs subvolume snapshot "$_snap" "$_current" >/dev/null \
        && log_info "Rolled back to '$_name'. Old root saved as $(basename "$_backup"). Reboot required."
}

backend_status() {
    _pre="${1:-}"
    _post="${2:-}"
    _bdfs_check || return 1

    if [ -z "$_pre" ]; then
        backend_list
        return
    fi

    _btrfs_mount=$(findmnt -no TARGET -t btrfs / 2>/dev/null || echo "/")
    _pre_path="${_btrfs_mount}/${_pre}"

    if [ -n "$_post" ]; then
        _post_path="${_btrfs_mount}/${_post}"
        btrfs subvolume show "$_pre_path" 2>/dev/null
        echo "---"
        btrfs subvolume show "$_post_path" 2>/dev/null
    else
        btrfs subvolume show "$_pre_path" 2>/dev/null
    fi
}
