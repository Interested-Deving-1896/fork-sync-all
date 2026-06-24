# Distro-agnostic policy

This document records every decision made to keep btrfs-dwarfs-framework
and its integrated projects free of distribution-specific assumptions.

## Principles

1. **No package manager commands in scripts.**  Install instructions use
   generic language ("install via your package manager") and list the
   package name for common distributions in a table, not inline commands.

2. **No hardcoded usernames, hostnames, or device paths.**  All such values
   are read from environment variables or config files with documented
   defaults.

3. **No desktop environment assumptions.**  Notification backends default to
   `systemd-cat` (journald).  Email and desktop notifications are opt-in.

4. **No bootloader assumptions.**  Boot integration supports both
   `initramfs-tools` (Debian/Ubuntu) and `dracut` (Fedora/Arch/openSUSE).
   The install script auto-detects which is present.

5. **No init system assumptions beyond systemd.**  All systemd units use
   `ConditionPathExists` guards so they are silently skipped when the
   relevant tools are absent.

6. **SSD/HDD detection is runtime, not compile-time.**  `bdfs-genfstab.sh`
   and `bdfs-balance.sh` probe `lsblk -d -o ROTA` at runtime.

## Removed items (from upstream sources)

| Source project | Removed item | Reason |
|---|---|---|
| btrfs-genfstab | Hardcoded `@`, `@home`, `@srv` subvolume names | Replaced by `btrfs subvolume list` introspection |
| btrfs-genfstab | Arch/CachyOS/Alpine badges | Marketing, not technical |
| btrfs-genfstab | `btrfsfstabcompressedalpine.sh` as separate file | Merged into single script with `--no-compress` |
| btrfs-home-directory-snapshots | `apt-get install ecryptfs-utils` / `dnf install` | Replaced with generic install note |
| btrfs-home-directory-snapshots | `adduser --btrfs-subvolume-home` (Debian-specific) | Replaced with `useradd` example |
| btrfs-backup | `gabx` hardcoded username | Replaced with `$(logname)` / `BACKUP_USER` |
| btrfs-backup | `magnolia` hardcoded hostname | Removed |
| btrfs-backup | `/dev/sda1` hardcoded backup device | `BDFS_BACKUP_DEVICE` in `bdfs.conf` |
| btrfs-backup | `s-nail` + Gmail `.mailrc` | Removed from tracked files; documented as opt-in |
| btrfs-backup | `COSMIC` desktop references | Removed |
| btrfs-backup | `yay -S` (AUR helper) | Removed |
| btrfs-backup | `pacman` hook for homed-identity-check | Replaced with generic systemd `.path` unit |
| btrfs-backup | `limine-snapper-sync` (Arch AUR) | Moved to `doc/bootloader-integration.md` |
| btrfs-backup | `debootstrap` as sole install example | Added `dnf --installroot` and `pacstrap` alternatives |
| btrfs-backup | `update-grub` vs `grub2-mkconfig` | Handled in `boot-integration.md` |
| btrfs-scrub.sh | Hardcoded `/` and `/backup` mountpoints | Read from `/etc/bdfs/scrub.conf` or auto-detected |
| btrfs-scrub.sh | Hardcoded log path `/backup/analysis_daily/` | `HOMED_LOG` env var with `/var/log/` default |
| homed-identity-check | `pacman` hook | Replaced with systemd `.path` unit |
| homed-identity-check | Hardcoded username `gabx` | `HOMED_USER` env var, auto-detected from `homectl list` |
| homed-identity-check | French comments | Translated to English |
| homed-identity-check | `s-nail` email notification | Removed; log to journald via `systemd-cat` |

## Package name reference

Tools required by the framework, by distribution:

| Tool | Debian/Ubuntu | Fedora/RHEL | Arch | Alpine | openSUSE |
|---|---|---|---|---|---|
| btrfs-progs | `btrfs-progs` | `btrfs-progs` | `btrfs-progs` | `btrfs-progs` | `btrfsprogs` |
| dwarfs | build from source | build from source | `dwarfs-bin` (AUR) | build from source | build from source |
| fuse-overlayfs | `fuse-overlayfs` | `fuse-overlayfs` | `fuse-overlayfs` | `fuse-overlayfs` | `fuse-overlayfs` |
| python3-cryptography | `python3-cryptography` | `python3-cryptography` | `python-cryptography` | `py3-cryptography` | `python3-cryptography` |
| findmnt | `util-linux` | `util-linux` | `util-linux` | `util-linux` | `util-linux` |
| rsync | `rsync` | `rsync` | `rsync` | `rsync` | `rsync` |

## Notification backend

All scripts default to `systemd-cat` for logging.  To enable email
notifications, set in `/etc/bdfs/bdfs.conf`:

```ini
[notify]
email = admin@example.com
# mail_command = /usr/bin/mail   # any POSIX mail(1) compatible binary
```

The scripts check for `BDFS_NOTIFY_EMAIL` in the environment and fall back
to `systemd-cat` if unset or if the mail binary is absent.
