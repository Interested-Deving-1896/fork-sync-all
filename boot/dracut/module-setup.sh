#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# dracut module: 90bdfs
#
# Install this directory as /usr/lib/dracut/modules.d/90bdfs/
# and rebuild the initramfs:
#   dracut --force --add bdfs /boot/initramfs-$(uname -r).img $(uname -r)

check() {
    # Only include this module if bdfs.root is on the kernel cmdline
    # or if explicitly requested with --add bdfs
    return 255  # 255 = include only if explicitly requested
}

depends() {
    echo "btrfs fuse"
}

install() {
    # Kernel modules
    instmods btrfs fuse overlay

    # Binaries
    for bin in dwarfs dwarfsextract fusermount3 btrfs bdfs; do
        if command -v "$bin" &>/dev/null; then
            inst_binary "$(command -v "$bin")"
        fi
    done

    # The boot script
    inst_hook pre-mount 50 "$moddir/bdfs-root.sh"

    # Configuration
    [ -f /etc/bdfs/boot.conf ] && inst_simple /etc/bdfs/boot.conf
}
