#!/usr/bin/env bash
# bdfs-dev-overlay.sh — overlayfs ephemeral backend for bdfs dev
#
# Creates an overlayfs workspace with the source path as the read-only lower
# layer and a tmpfs or directory as the writable upper layer. Works on any
# filesystem — no BTRFS required.
#
# This backend is intentionally ephemeral: changes in the upper layer are
# lost when the workspace is dropped unless explicitly saved via:
#   bdfs dev commit  (OSTree)
#   bdfs dev demote  (DwarFS archive)
#   --upper PATH     (persist upper layer to a specific directory)
#
# Layout:
#   lower:  bind-mount of source (read-only)
#   upper:  tmpfs or user-provided directory (writable changes)
#   work:   overlayfs work directory (same filesystem as upper)
#   merged: the unified writable view (mountpoint)
#
# Sourced by bdfs-dev.sh — do not execute directly.

# ── Backend interface ─────────────────────────────────────────────────────────

backend_create() {
    local name="$1"
    local source="$2"
    local tmpfs_size="${3:-2G}"
    local upper_hint="${4:-}"

    check_deps_overlay

    [[ -d "$source" ]] || die "Source path does not exist: $source" 3

    local ws_dir
    ws_dir="$(workspace_dir "$name")"

    local lower_dir="${ws_dir}/lower"
    local upper_dir="${ws_dir}/upper"
    local work_dir="${ws_dir}/work"
    local merged_dir="${ws_dir}/merged"

    mkdir -p "$lower_dir" "$upper_dir" "$work_dir" "$merged_dir"

    # Step 1: Bind-mount source as read-only lower layer
    # Using a bind mount rather than the source directly so overlayfs
    # doesn't need the source to be on the same filesystem as upper/work.
    info "Bind-mounting source (read-only): $source → $lower_dir"
    mount --bind "$source" "$lower_dir"
    mount --make-rslave "$lower_dir"
    mount -o remount,ro,bind "$lower_dir"

    workspace_set "$name" lower_dir "$lower_dir"
    workspace_set "$name" source    "$source"

    # Step 2: Set up upper layer
    if [[ -n "$upper_hint" ]]; then
        # Persistent upper directory — user controls its lifecycle
        mkdir -p "$upper_hint"
        # work dir must be on the same filesystem as upper
        local hint_work="${upper_hint}/.bdfs-work-${name}"
        mkdir -p "$hint_work"
        upper_dir="$upper_hint"
        work_dir="$hint_work"
        workspace_set "$name" upper_backend  "dir"
        workspace_set "$name" upper_hint_dir "$upper_hint"
        workspace_set "$name" work_dir       "$work_dir"
        info "Using persistent upper directory: $upper_dir"
    else
        # tmpfs upper layer — ephemeral, lives in RAM
        info "Mounting tmpfs upper layer (size: $tmpfs_size)"
        mount -t tmpfs -o "size=${tmpfs_size},mode=0755" tmpfs "$upper_dir"
        # work dir inside the tmpfs
        mkdir -p "${upper_dir}/.work"
        work_dir="${upper_dir}/.work"
        workspace_set "$name" upper_backend "tmpfs"
        workspace_set "$name" tmpfs_size    "$tmpfs_size"
        workspace_set "$name" work_dir      "$work_dir"
        upper_dir="${upper_dir}"  # actual upper is the tmpfs root
        # Separate upper from work inside the tmpfs
        local actual_upper="${ws_dir}/upper/changes"
        mkdir -p "$actual_upper"
        upper_dir="$actual_upper"
    fi

    workspace_set "$name" upper_dir "$upper_dir"

    # Step 3: Mount overlayfs
    info "Mounting overlayfs: $merged_dir"
    mount -t overlay overlay \
        -o "lowerdir=${lower_dir},upperdir=${upper_dir},workdir=${work_dir}" \
        "$merged_dir"

    workspace_set "$name" mountpoint "$merged_dir"

    ok "Overlay workspace ready at $merged_dir"
    info "  lower (read-only): $lower_dir"
    info "  upper (writable):  $upper_dir"
    info "  Changes are $([ -n "$upper_hint" ] && echo "persistent in $upper_hint" || echo "ephemeral (tmpfs, lost on drop)")"
}

backend_drop() {
    local name="$1"

    local merged_dir lower_dir upper_dir upper_backend upper_hint_dir
    merged_dir="$(workspace_get "$name" mountpoint)"
    lower_dir="$(workspace_get "$name" lower_dir)"
    upper_dir="$(workspace_get "$name" upper_dir)"
    upper_backend="$(workspace_get "$name" upper_backend)"
    upper_hint_dir="$(workspace_get "$name" upper_hint_dir)"

    # Unmount in reverse order
    if [[ -n "$merged_dir" ]] && mountpoint -q "$merged_dir" 2>/dev/null; then
        umount "$merged_dir" && info "Unmounted overlayfs: $merged_dir"
    fi

    if [[ -n "$lower_dir" ]] && mountpoint -q "$lower_dir" 2>/dev/null; then
        umount "$lower_dir" && info "Unmounted lower bind: $lower_dir"
    fi

    case "$upper_backend" in
        tmpfs)
            # The tmpfs is mounted at the parent of upper_dir (ws_dir/upper)
            local ws_dir
            ws_dir="$(workspace_dir "$name")"
            local tmpfs_mount="${ws_dir}/upper"
            if mountpoint -q "$tmpfs_mount" 2>/dev/null; then
                umount "$tmpfs_mount" && info "Unmounted tmpfs upper: $tmpfs_mount"
            fi
            ;;
        dir)
            # User-provided — don't delete, just clean up the work dir
            if [[ -n "$upper_hint_dir" ]]; then
                local hint_work="${upper_hint_dir}/.bdfs-work-${name}"
                [[ -d "$hint_work" ]] && rm -rf "$hint_work"
                warn "Upper directory '$upper_hint_dir' preserved — contains your changes"
            fi
            ;;
    esac

    ok "Overlay workspace '$name' torn down"
}

# ── Save helper (export upper layer changes) ──────────────────────────────────

# Called externally to extract the upper layer diff to a tar archive
# before dropping an ephemeral workspace.
backend_save_upper() {
    local name="$1"
    local dest="$2"   # path to output .tar.gz

    local upper_dir
    upper_dir="$(workspace_get "$name" upper_dir)"
    [[ -z "$upper_dir" ]] && die "No upper_dir for workspace '$name'" 2
    [[ -d "$upper_dir" ]] || die "Upper dir does not exist: $upper_dir" 3

    info "Saving upper layer changes to: $dest"
    tar -czf "$dest" -C "$upper_dir" .
    ok "Saved $(du -sh "$dest" | cut -f1) of changes to $dest"
}
