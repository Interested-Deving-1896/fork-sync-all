#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# dracut pre-mount hook: bdfs-root.sh
#
# Equivalent to the initramfs-tools script but for dracut-based systems
# (Fedora, RHEL, Arch, etc.).
#
# See boot/initramfs/scripts/bdfs-root for full documentation of
# boot parameters and the mount flow.

type getarg >/dev/null 2>&1 || . /lib/dracut-lib.sh

BDFS_ROOT=$(getarg bdfs.root=)
[ -z "$BDFS_ROOT" ] && exit 0

BDFS_IMAGE=$(getarg bdfs.image=)
BDFS_UPPER_DEV=$(getarg bdfs.upper=)
BDFS_UPPER_SUBVOL=$(getarg bdfs.upper.subvol=)
BDFS_UPPER_SUBVOL=${BDFS_UPPER_SUBVOL:-upper}
BDFS_ROLLBACK=$(getargbool 0 bdfs.rollback)

BDFS_BTRFS_MNT="/run/bdfs/btrfs_part"
BDFS_LOWER_MNT="/run/bdfs/lower"
BDFS_UPPER_MNT="/run/bdfs/upper"

info "bdfs: mounting immutable root from $BDFS_ROOT:$BDFS_IMAGE"

# Load modules
modprobe btrfs   2>/dev/null || true
modprobe fuse    2>/dev/null || true
modprobe overlay 2>/dev/null || true

# Mount BTRFS partition
mkdir -p "$BDFS_BTRFS_MNT"
mount -t btrfs -o ro,noatime "$BDFS_ROOT" "$BDFS_BTRFS_MNT" \
    || { warn "bdfs: cannot mount $BDFS_ROOT"; exit 1; }

# Resolve image
IMAGE_PATH="${BDFS_BTRFS_MNT}${BDFS_IMAGE}"
if [ "$BDFS_ROLLBACK" = "1" ]; then
    PREV="${IMAGE_PATH%.dwarfs}.prev.dwarfs"
    [ -f "$PREV" ] && IMAGE_PATH="$PREV" \
        && info "bdfs: rollback: using $PREV"
fi
[ -f "$IMAGE_PATH" ] || { warn "bdfs: image not found: $IMAGE_PATH"; exit 1; }

# Mount DwarFS lower layer
mkdir -p "$BDFS_LOWER_MNT"
dwarfs "$IMAGE_PATH" "$BDFS_LOWER_MNT" \
    -o cache_size=256m,ro,allow_other,nonempty \
    || { warn "bdfs: dwarfs mount failed"; exit 1; }

# Mount writable upper layer
mkdir -p "$BDFS_UPPER_MNT"
if [ -n "$BDFS_UPPER_DEV" ] && [ -b "$BDFS_UPPER_DEV" ]; then
    mount -t btrfs -o rw,noatime "$BDFS_UPPER_DEV" "$BDFS_UPPER_MNT" \
        || { warn "bdfs: cannot mount upper $BDFS_UPPER_DEV"; exit 1; }
    btrfs subvolume show "$BDFS_UPPER_MNT/$BDFS_UPPER_SUBVOL" \
        >/dev/null 2>&1 \
        || btrfs subvolume create "$BDFS_UPPER_MNT/$BDFS_UPPER_SUBVOL"
    UPPER_DIR="$BDFS_UPPER_MNT/$BDFS_UPPER_SUBVOL"
    WORK_DIR="$BDFS_UPPER_MNT/.bdfs_work"
    mkdir -p "$WORK_DIR"
else
    info "bdfs: using tmpfs upper layer (ephemeral)"
    mount -t tmpfs -o size=2g tmpfs "$BDFS_UPPER_MNT"
    UPPER_DIR="$BDFS_UPPER_MNT/upper"
    WORK_DIR="$BDFS_UPPER_MNT/work"
    mkdir -p "$UPPER_DIR" "$WORK_DIR"
fi

# Mount overlayfs as the new root
mount -t overlay overlay \
    -o "lowerdir=$BDFS_LOWER_MNT,upperdir=$UPPER_DIR,workdir=$WORK_DIR" \
    "$NEWROOT" \
    || { warn "bdfs: overlayfs mount failed"; exit 1; }

# Expose BTRFS partition and lower mount inside new root
mkdir -p "$NEWROOT/run/bdfs/btrfs_part" "$NEWROOT/run/bdfs/lower"
mount --bind "$BDFS_BTRFS_MNT" "$NEWROOT/run/bdfs/btrfs_part"
mount --bind "$BDFS_LOWER_MNT"  "$NEWROOT/run/bdfs/lower"

info "bdfs: immutable root ready"
