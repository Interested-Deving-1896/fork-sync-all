# IncusOS Integration

Bridges [IncusOS](https://github.com/lxc/incus-os)'s immutable OS image model
with btrfs-dwarfs-framework's snapshot and workspace capabilities.

IncusOS is an immutable, Debian-based OS dedicated to running
[Incus](https://linuxcontainers.org/incus). It uses `systemd-sysupdate` for
in-place updates and has a strong focus on UEFI Secure Boot and TPM 2.0.

## What this provides

| Script | Purpose |
|---|---|
| `bdfs-incusos.sh` | CLI wrapper: workspace, export, import, update, status |
| `bdfs-incusos.conf` | Site configuration (copy to `/etc/bdfs/incusos.conf`) |

## How it fits together

```
IncusOS root (immutable)
      │
      └──bdfs-incusos workspace──► writable workspace (inspect/modify safely)
      │
      └──bdfs-incusos export──► DwarFS image ──► bdfs-incusos import──► Incus image
                                                                              │
                                                                    incus launch <alias>
```

The primary use cases are:

1. **Safe inspection** — create a writable workspace on top of the live
   IncusOS root to inspect or test configuration changes without touching
   the immutable base.

2. **Image archival** — export the IncusOS root as a compressed DwarFS image
   for backup, transfer, or offline analysis.

3. **Incus image creation** — import a DwarFS archive as an Incus container
   or VM image, enabling IncusOS-derived images to be launched as Incus
   instances on any Incus host.

## Install

```bash
install -m 755 bdfs-incusos.sh /usr/local/bin/bdfs-incusos
install -m 644 bdfs-incusos.conf /etc/bdfs/incusos.conf
```

## Usage

```bash
# Create a mutable workspace on top of the live IncusOS root
bdfs-incusos workspace --name my-incusos-workspace

# Inspect the workspace
bdfs dev shell my-incusos-workspace

# Export the live IncusOS root as a DwarFS image
bdfs-incusos export \
    --out /var/lib/bdfs/incusos-images/incusos-$(date +%Y%m%d).dwarfs

# Import the DwarFS image as an Incus container image
bdfs-incusos import \
    /var/lib/bdfs/incusos-images/incusos-20260525.dwarfs \
    --alias incusos-20260525

# Launch an Incus instance from the imported image
incus launch incusos-20260525 my-incusos-instance

# Check for IncusOS updates
bdfs-incusos update --check

# Apply update (staged, activates on reboot)
bdfs-incusos update

# Show IncusOS version, Incus status, and active bdfs workspaces
bdfs-incusos status
```

## Dependencies

- `bdfs` — btrfs-dwarfs-framework
- `mkdwarfs` / `dwarfs` — for export/import
- `incus` — for `import` (importing DwarFS images as Incus images)
- `fuse` — for import (mounts DwarFS image during Incus image creation)
- `systemd-sysupdate` or `incus-os` CLI — for `update`

## Notes on IncusOS immutability

IncusOS uses an A/B partition scheme with `systemd-sysupdate`. The root
filesystem is read-only. `bdfs-incusos workspace` uses `bdfs dev` with the
overlay backend (no BTRFS required on the IncusOS host) to create a writable
view without modifying the immutable base.

For persistent changes, use `bdfs dev commit` to save the workspace state,
then rebuild the IncusOS image via the upstream
[mkosi](https://github.com/systemd/mkosi)-based build system.
