#!/usr/bin/env bash
# bdfs-dev-btrfs.sh — BTRFS backend for bdfs dev
#
# Creates a writable BTRFS snapshot of a source path. The source must be
# either a BTRFS subvolume or a directory on a BTRFS filesystem.
#
# If the source is an OSTree deployment root (detected by the presence of
# .ostree-deployment or usr/lib/os-release with ostree markers), a read-only
# snapshot is taken first to ensure consistency, then a writable snapshot is
# taken from that.
#
# Sourced by bdfs-dev.sh — do not execute directly.

# Inherit logging functions from parent (info, ok, warn, die)
# Inherit workspace_* functions from parent

# ── Helpers ───────────────────────────────────────────────────────────────────

_btrfs_find_mount() {
    # Find the BTRFS mount point that contains a given path
    local path="$1"
    local real_path
    real_path="$(realpath "$path")"

    while [[ "$real_path" != "/" ]]; do
        if findmnt -n -o FSTYPE "$real_path" 2>/dev/null | grep -q "^btrfs$"; then
            echo "$real_path"
            return 0
        fi
        real_path="$(dirname "$real_path")"
    done

    # Check root
    if findmnt -n -o FSTYPE / 2>/dev/null | grep -q "^btrfs$"; then
        echo "/"
        return 0
    fi

    return 1
}

_btrfs_is_subvolume() {
    local path="$1"
    btrfs subvolume show "$path" &>/dev/null
}

_is_ostree_root() {
    local path="$1"
    # OSTree deployment roots have a .ostree-deployment file or
    # a usr/ directory with lib/os-release
    [[ -f "${path}/.ostree-deployment" ]] || \
    [[ -f "${path}/usr/lib/os-release" && -L "${path}/etc" ]]
}

# ── Backend interface ─────────────────────────────────────────────────────────

backend_create() {
    local name="$1"
    local source="$2"

    check_deps_btrfs

    [[ -d "$source" ]] || die "Source path does not exist: $source" 3

    # Verify source is on BTRFS
    local btrfs_mount
    btrfs_mount="$(_btrfs_find_mount "$source")" || \
        die "Source '$source' is not on a BTRFS filesystem — use --backend overlay instead" 3

    info "BTRFS mount: $btrfs_mount"

    # Determine snapshot storage location
    local snap_base="${BDFS_BTRFS_MOUNT:-$btrfs_mount}"
    local snap_dir="${snap_base}/.bdfs-dev-snapshots"
    mkdir -p "$snap_dir"

    local snap_path="${snap_dir}/${name}"

    # If source is an OSTree deployment root, take a read-only snapshot first
    # for consistency, then a writable snapshot from that
    if _is_ostree_root "$source"; then
        info "Detected OSTree deployment root — taking consistent snapshot"
        local ro_snap="${snap_dir}/${name}-ro-base"

        if _btrfs_is_subvolume "$source"; then
            btrfs subvolume snapshot -r "$source" "$ro_snap"
        else
            # Not a subvolume — create one from the directory contents
            btrfs subvolume create "$ro_snap"
            cp -a --reflink=auto "${source}/." "$ro_snap/"
            btrfs property set "$ro_snap" ro true
        fi

        # Writable snapshot from the read-only base
        btrfs subvolume snapshot "$ro_snap" "$snap_path"

        # Clean up the read-only base (it was just an intermediate)
        btrfs subvolume delete "$ro_snap"

        workspace_set "$name" ostree_source "true"
    else
        if _btrfs_is_subvolume "$source"; then
            btrfs subvolume snapshot "$source" "$snap_path"
        else
            # Plain directory on BTRFS — create a new subvolume and reflink copy
            btrfs subvolume create "$snap_path"
            cp -a --reflink=auto "${source}/." "$snap_path/"
        fi
    fi

    workspace_set "$name" snapshot_path "$snap_path"
    workspace_set "$name" mountpoint    "$snap_path"
    workspace_set "$name" btrfs_mount   "$btrfs_mount"

    ok "BTRFS snapshot created at $snap_path"
}

backend_drop() {
    local name="$1"

    local snap_path mountpoint
    snap_path="$(workspace_get "$name" snapshot_path)"
    mountpoint="$(workspace_get "$name" mountpoint)"

    # Unmount if it's separately mounted (shouldn't be for BTRFS snapshots,
    # but guard anyway)
    if [[ -n "$mountpoint" ]] && mountpoint -q "$mountpoint" 2>/dev/null; then
        umount "$mountpoint" || warn "Could not unmount $mountpoint"
    fi

    if [[ -n "$snap_path" ]] && [[ -d "$snap_path" ]]; then
        if _btrfs_is_subvolume "$snap_path"; then
            btrfs subvolume delete "$snap_path"
        else
            rm -rf "$snap_path"
        fi
        ok "BTRFS snapshot deleted: $snap_path"
    else
        warn "Snapshot path not found or already removed: $snap_path"
    fi
}
