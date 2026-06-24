# Bootloader integration

The BDFS boot integration (`boot/`) works with any bootloader that can pass
kernel command-line parameters.  The initramfs hook handles the actual mount
setup; the bootloader only needs to set the `bdfs.*` parameters.

## Kernel command-line parameters

```
bdfs.root=<device>      Block device containing the BTRFS filesystem
bdfs.image=<path>       Path to the .dwarfs image within the BTRFS filesystem
bdfs.upper=<device>     Block device for the writable BTRFS upper layer
bdfs.workdir=<path>     Overlayfs workdir path (default: /.bdfs_work)
bdfs.cache_mb=<n>       DwarFS FUSE cache size in MiB (default: 256)
```

## GRUB 2

```
# /etc/grub.d/40_custom or /boot/grub/grub.cfg snippet
menuentry "OpenOS (bdfs)" {
    linux /boot/vmlinuz root=/dev/sda2 \
        bdfs.root=/dev/sda2 \
        bdfs.image=/images/system.dwarfs \
        bdfs.upper=/dev/sda3
    initrd /boot/initrd.img
}
```

Regenerate after editing:
- Debian/Ubuntu: `update-grub`
- Fedora/RHEL:   `grub2-mkconfig -o /boot/grub2/grub.cfg`
- Arch:          `grub-mkconfig -o /boot/grub/grub.cfg`
- openSUSE:      `grub2-mkconfig -o /boot/grub2/grub.cfg`

## systemd-boot

```ini
# /boot/loader/entries/openos-bdfs.conf
title   OpenOS (bdfs)
linux   /vmlinuz
initrd  /initrd.img
options root=/dev/sda2 \
        bdfs.root=/dev/sda2 \
        bdfs.image=/images/system.dwarfs \
        bdfs.upper=/dev/sda3
```

## Limine

```toml
# /etc/limine/limine.conf
[[entry]]
name = "OpenOS (bdfs)"
protocol = linux
kernel_path = boot():/vmlinuz
module_path = boot():/initrd.img
cmdline = root=/dev/sda2 bdfs.root=/dev/sda2 bdfs.image=/images/system.dwarfs bdfs.upper=/dev/sda3
```

Limine snapshot boot integration (Arch-specific `limine-snapper-sync`) is
not part of the core framework.  If you use Limine + Snapper on Arch, the
`limine-snapper-sync` AUR package handles bootloader entry generation for
Snapper snapshots independently of bdfs.

## Bootable snapshots

To make a DwarFS image bootable:

1. Create the image from a known-good deployment:
   ```
   bdfs export --partition <uuid> --subvol-id <id> \
               --btrfs-mount /mnt/btrfs --name system-2026-04-20
   ```

2. Add a bootloader entry pointing to the image:
   ```
   bdfs.image=/images/system-2026-04-20.dwarfs
   ```

3. The initramfs hook mounts the image read-only as the lower layer and
   creates a fresh writable BTRFS subvolume as the upper layer on each boot.
   Changes made during the session are discarded on reboot (stateless boot)
   unless `bdfs.persist=1` is set, in which case the upper layer is retained.
