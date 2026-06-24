# BDFS Immutable Boot Integration

## Overview

The boot integration layer mounts a DwarFS image as the immutable system root
with a BTRFS writable overlay, enabling:

- **Instant rollback** — boot the previous image with `bdfs.rollback` on the
  kernel cmdline
- **Atomic updates** — new images are verified with `dwarfsck` before being
  rotated into place via `rename(2)`
- **Persistent or ephemeral writes** — use a BTRFS upper layer for persistent
  changes, or omit it for a live/kiosk mode where changes are lost on reboot
- **BTRFS snapshots of image collections** — every image rotation creates a
  BTRFS snapshot of the images subvolume

## Boot Flow

```
GRUB
  │  bdfs.root=/dev/sda2
  │  bdfs.image=/images/system.dwarfs
  │  bdfs.upper=/dev/sda3
  ▼
initramfs / dracut pre-mount hook (bdfs-root)
  │
  ├─ mount /dev/sda2 (BTRFS) → /run/bdfs/btrfs_part  [read-only]
  │
  ├─ dwarfs /run/bdfs/btrfs_part/images/system.dwarfs
  │         → /run/bdfs/lower                         [read-only FUSE]
  │
  ├─ mount /dev/sda3 (BTRFS) → /run/bdfs/upper        [read-write]
  │   └─ btrfs subvolume create upper  (if absent)
  │
  ├─ mount overlayfs → /root (or $NEWROOT for dracut)
  │     lower = /run/bdfs/lower   (DwarFS)
  │     upper = /run/bdfs/upper/upper  (BTRFS subvol)
  │     work  = /run/bdfs/upper/.bdfs_work
  │
  └─ bind-mount /run/bdfs/btrfs_part → /root/run/bdfs/btrfs_part
     (so the running system can manage images)

systemd / init
  └─ normal boot from /root
```

## Disk Layout

```
/dev/sda1   EFI / boot partition
/dev/sda2   BTRFS — image store (read-only at boot)
  └── /images/
        ├── system.dwarfs        ← active root image
        ├── system.prev.dwarfs   ← previous image (rollback target)
        └── system.new.dwarfs    ← staging area during update
/dev/sda3   BTRFS — writable upper layer
  └── /upper/                    ← overlayfs upper dir (persistent changes)
      /.bdfs_work/               ← overlayfs work dir
```

## Kernel Parameters

| Parameter | Description | Example |
|---|---|---|
| `bdfs.root=` | BTRFS partition holding images | `/dev/sda2` |
| `bdfs.image=` | Path to image within partition | `/images/system.dwarfs` |
| `bdfs.upper=` | BTRFS partition for writable layer | `/dev/sda3` |
| `bdfs.upper.subvol=` | Subvolume name (default: `upper`) | `upper` |
| `bdfs.rollback` | Boot `.prev` image instead | _(flag)_ |
| `bdfs.shell` | Drop to shell before mounting | _(flag, debug)_ |

## Installation

```bash
# Detect initramfs system automatically
sudo bash boot/install.sh

# Or specify explicitly
sudo bash boot/install.sh --initramfs-tools
sudo bash boot/install.sh --dracut

# Dry run (show what would be done)
sudo bash boot/install.sh --dry-run
```

Then edit `/etc/default/grub`:

```
GRUB_CMDLINE_LINUX="... bdfs.root=/dev/sda2 bdfs.image=/images/system.dwarfs bdfs.upper=/dev/sda3"
```

And rebuild GRUB:

```bash
sudo update-grub   # Debian/Ubuntu
sudo grub2-mkconfig -o /boot/grub2/grub.cfg  # Fedora/RHEL
```

## Creating the Initial Root Image

```bash
# 1. Install a base system into a directory
debootstrap stable /tmp/rootfs http://deb.debian.org/debian

# 2. Create a DwarFS image from it
mkdwarfs -i /tmp/rootfs -o /mnt/images/system.dwarfs \
    --compression zstd --block-size-bits 22 \
    --categorize --num-workers 4

# 3. Verify the image
dwarfsck /mnt/images/system.dwarfs

# 4. Register with the framework
bdfs partition add --type btrfs-backed \
    --device /dev/sda2 --label images --mount /mnt/images

bdfs verify --partition <uuid>
```

## Image Updates

The `bdfs-image-update` script manages the image lifecycle:

```bash
# Manual update from a local file
sudo bdfs-image-update --image /path/to/new_system.dwarfs

# Dry run (verify only, no rotation)
sudo bdfs-image-update --image /path/to/new_system.dwarfs --dry-run

# Force update even if hash matches
sudo bdfs-image-update --image /path/to/new_system.dwarfs --force

# Provide an explicit SHA-256 hash (overrides sidecar file)
sudo bdfs-image-update --image /path/to/new_system.dwarfs \
    --sha256 abc123...

# Provide a local GPG signature file
sudo bdfs-image-update --image /path/to/new_system.dwarfs \
    --sig /path/to/new_system.dwarfs.sig

# Skip GPG verification
sudo bdfs-image-update --image /path/to/new_system.dwarfs --no-gpg
```

Automatic updates run via the systemd timer (daily by default):

```bash
systemctl enable --now bdfs-image-update.timer
systemctl status bdfs-image-update.timer
```

Configure the update URL and verification in `/etc/bdfs/boot.conf`:

```ini
update_url = https://example.com/images/system.dwarfs
# Optional: inline SHA-256 (takes precedence over .sha256 sidecar)
update_checksum = <sha256hex>
# Path to GPG keyring with trusted release signing key(s)
gpg_keyring = /etc/bdfs/trusted.gpg
# Set to 1 to require a valid GPG signature on every update
require_gpg = 0
```

### Verification pipeline

For each update, `bdfs-image-update` runs these checks in order before
rotating the image into place:

1. **SHA-256** — computed over the downloaded image and compared against
   (in priority order): `--sha256` CLI argument, `update_checksum` in
   `boot.conf`, or a `.sha256` sidecar file fetched from
   `${update_url}.sha256`.

2. **GPG detached signature** — the `.sha256` sidecar file is verified
   against a `.sig` file fetched from `${update_url}.sig` (or provided
   via `--sig`).  The signature is checked against the keyring at
   `gpg_keyring`.  A present-but-invalid signature is always fatal.
   A missing signature produces a warning unless `require_gpg = 1`.

3. **dwarfsck** — structural integrity of the DwarFS image itself.

### Setting up the GPG keyring

```bash
# Import the release signing key into the BDFS keyring
gpg --no-default-keyring \
    --keyring /etc/bdfs/trusted.gpg \
    --import /path/to/release-key.asc

# Verify the keyring contains the expected key
gpg --no-default-keyring \
    --keyring /etc/bdfs/trusted.gpg \
    --list-keys
```

### Signing images (server side)

```bash
# Generate a SHA-256 sidecar
sha256sum system.dwarfs > system.dwarfs.sha256

# Sign the sidecar with the release key
gpg --detach-sign --armor \
    --local-user release@example.com \
    system.dwarfs.sha256
mv system.dwarfs.sha256.asc system.dwarfs.sig

# Publish all three files
rsync system.dwarfs system.dwarfs.sha256 system.dwarfs.sig \
    user@example.com:/var/www/images/
```

## Rollback

To roll back to the previous image, add `bdfs.rollback` to the kernel cmdline
at boot (via GRUB edit mode, `e` key):

```
linux /vmlinuz ... bdfs.root=/dev/sda2 bdfs.image=/images/system.dwarfs bdfs.rollback
```

Or permanently via `/etc/default/grub` until the issue is resolved.

The `.prev` image is retained until the next successful update rotation.

## Live / Kiosk Mode

Omit `bdfs.upper=` to use a tmpfs upper layer. All writes are lost on reboot:

```
GRUB_CMDLINE_LINUX="... bdfs.root=/dev/sda2 bdfs.image=/images/system.dwarfs"
```

This is useful for kiosk systems, CI runners, or read-only appliances.

## Comparison with Similar Systems

| Feature | BDFS | OSTree | NixOS | ChromeOS |
|---|---|---|---|---|
| Immutable base | DwarFS image | OSTree repo | Nix store | dm-verity |
| Writable layer | BTRFS overlay | bind mounts | tmpfs/persist | ext4 stateful |
| Rollback | `.prev` image | `ostree admin rollback` | `nixos-rebuild` | Powerwash |
| Compression | 10–16× (DwarFS) | none | store-level | squashfs |
| Snapshots | BTRFS CoW | OSTree commits | Nix generations | none |
| Update atomicity | `rename(2)` | hardlink tree | Nix profile | partition swap |
