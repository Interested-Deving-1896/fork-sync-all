#!/usr/bin/env bash
# bdfs-dev-dwarfs.sh — DwarFS backend for bdfs dev
#
# Mounts a DwarFS image read-only as the lower layer of an overlayfs,
# with a writable upper layer (BTRFS subvolume if available, tmpfs otherwise).
# This allows working on compressed/archived roots without full extraction.
#
# Layout:
#   lower:  DwarFS FUSE mount of the image (read-only)
#   upper:  BTRFS subvolume or tmpfs (writable changes)
#   work:   overlayfs work directory
#   merged: the unified writable view (mountpoint)
#
# Sourced by bdfs-dev.sh — do not execute directly.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "[bdfs dev] ERROR: bdfs-dev-dwarfs.sh must be sourced by bdfs-dev.sh" >&2
    exit 64
fi

# ── Helpers ───────────────────────────────────────────────────────────────────

_dwarfs_detect_upper_backend() {
    # Prefer BTRFS for the upper layer if available, fall back to tmpfs
    local state_dir="$1"
    local btrfs_mount="${BDFS_BTRFS_MOUNT:-}"

    if [[ -n "$btrfs_mount" ]] && \
       findmnt -n -o FSTYPE "$btrfs_mount" 2>/dev/null | grep -q "^btrfs$"; then
        echo "btrfs"
    else
        echo "tmpfs"
    fi
}

# ── Backend interface ─────────────────────────────────────────────────────────

backend_create() {
    local name="$1"
    local source="$2"       # path to .dwarfs image
    local tmpfs_size="${3:-2G}"
    local upper_hint="${4:-}"

    check_deps_dwarfs

    # Source can be a .dwarfs image or a directory containing one
    local image_path="$source"
    if [[ -d "$source" ]]; then
        # Look for a .dwarfs file inside
        image_path="$(find "$source" -maxdepth 1 -name "*.dwarfs" | head -1)"
        [[ -z "$image_path" ]] && die "No .dwarfs image found in: $source" 3
        info "Found DwarFS image: $image_path"
    fi

    [[ -f "$image_path" ]] || die "DwarFS image not found: $image_path" 3

    local ws_dir
    ws_dir="$(workspace_dir "$name")"

    local lower_dir="${ws_dir}/lower"
    local upper_dir="${ws_dir}/upper"
    local work_dir="${ws_dir}/work"
    local merged_dir="${ws_dir}/merged"

    mkdir -p "$lower_dir" "$upper_dir" "$work_dir" "$merged_dir"

    # Step 1: Mount DwarFS image read-only as lower layer
    info "Mounting DwarFS image: $image_path → $lower_dir"
    dwarfs "$image_path" "$lower_dir" -o ro,allow_other 2>/dev/null || \
    dwarfs "$image_path" "$lower_dir" -o ro

    workspace_set "$name" dwarfs_image  "$image_path"
    workspace_set "$name" lower_dir     "$lower_dir"

    # Step 2: Set up upper layer
    local upper_backend
    upper_backend="$(_dwarfs_detect_upper_backend "$ws_dir")"

    if [[ -n "$upper_hint" ]]; then
        # Explicit upper directory provided
        mkdir -p "${upper_hint}/changes" "${upper_hint}/.bdfs-work-${name}"
        upper_dir="${upper_hint}/changes"
        work_dir="${upper_hint}/.bdfs-work-${name}"
        workspace_set "$name" upper_backend "dir"
        workspace_set "$name" upper_hint_dir "$upper_hint"
    elif [[ "$upper_backend" == "btrfs" ]]; then
        local btrfs_mount="${BDFS_BTRFS_MOUNT}"
        local snap_dir="${btrfs_mount}/.bdfs-dev-snapshots"
        mkdir -p "$snap_dir"
        local upper_base="${snap_dir}/${name}-upper"
        btrfs subvolume create "$upper_base"
        mkdir -p "${upper_base}/changes" "${upper_base}/work"
        upper_dir="${upper_base}/changes"
        work_dir="${upper_base}/work"
        workspace_set "$name" upper_backend "btrfs"
        workspace_set "$name" upper_btrfs_path "$upper_base"
    else
        # tmpfs upper layer
        info "Using tmpfs upper layer (size: $tmpfs_size)"
        local upper_mount="$upper_dir"
        mount -t tmpfs -o "size=${tmpfs_size},mode=0755" tmpfs "$upper_mount"
        mkdir -p "${upper_mount}/changes" "${upper_mount}/work"
        upper_dir="${upper_mount}/changes"
        work_dir="${upper_mount}/work"
        workspace_set "$name" upper_backend "tmpfs"
        workspace_set "$name" tmpfs_size    "$tmpfs_size"
        workspace_set "$name" upper_mount   "$upper_mount"
    fi

    workspace_set "$name" upper_dir "$upper_dir"
    workspace_set "$name" work_dir  "$work_dir"

    # Step 3: Mount overlayfs
    info "Mounting overlayfs: merged → $merged_dir"
    mount -t overlay overlay \
        -o "lowerdir=${lower_dir},upperdir=${upper_dir},workdir=${work_dir}" \
        "$merged_dir"

    workspace_set "$name" mountpoint "$merged_dir"

    ok "DwarFS workspace ready at $merged_dir"
    info "  lower (read-only): $lower_dir (DwarFS)"
    info "  upper (writable):  $upper_dir ($upper_backend)"
}

backend_drop() {
    local name="$1"

    local merged_dir lower_dir upper_dir upper_backend upper_btrfs_path upper_mount upper_hint_dir
    merged_dir="$(workspace_get "$name" mountpoint)"
    lower_dir="$(workspace_get "$name" lower_dir)"
    upper_dir="$(workspace_get "$name" upper_dir)"
    upper_backend="$(workspace_get "$name" upper_backend)"
    upper_btrfs_path="$(workspace_get "$name" upper_btrfs_path)"
    upper_mount="$(workspace_get "$name" upper_mount)"
    upper_hint_dir="$(workspace_get "$name" upper_hint_dir)"

    # Unmount in reverse order: merged → lower → upper (if tmpfs)
    if [[ -n "$merged_dir" ]] && mountpoint -q "$merged_dir" 2>/dev/null; then
        umount "$merged_dir" && info "Unmounted overlayfs: $merged_dir"
    fi

    if [[ -n "$lower_dir" ]] && mountpoint -q "$lower_dir" 2>/dev/null; then
        umount "$lower_dir" && info "Unmounted DwarFS: $lower_dir"
    fi

    case "$upper_backend" in
        tmpfs)
            if [[ -n "$upper_mount" ]] && mountpoint -q "$upper_mount" 2>/dev/null; then
                umount "$upper_mount" && info "Unmounted tmpfs upper: $upper_mount"
            fi
            ;;
        btrfs)
            if [[ -n "$upper_btrfs_path" ]] && [[ -d "$upper_btrfs_path" ]]; then
                btrfs subvolume delete "$upper_btrfs_path" && \
                    info "Deleted BTRFS upper subvolume: $upper_btrfs_path"
            fi
            ;;
        dir)
            # User-provided directory — don't delete it, just warn
            [[ -n "$upper_hint_dir" ]] && rm -rf -- "${upper_hint_dir}/.bdfs-work-${name}"
            warn "Upper directory '$upper_hint_dir' was user-provided — changes were not deleted"
            ;;
    esac

    ok "DwarFS workspace '$name' torn down"
}
