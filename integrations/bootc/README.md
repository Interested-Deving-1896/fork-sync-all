# bootc Integration

Bridges [bootc](https://github.com/bootc-dev/bootc)'s OCI-container-as-OS
model with btrfs-dwarfs-framework's snapshot and workspace capabilities.

## What this provides

| Script | Purpose |
|---|---|
| `bdfs-bootc.sh` | CLI wrapper: workspace, commit, switch, upgrade, export, status |
| `bdfs-bootc.conf` | Site configuration (copy to `/etc/bdfs/bootc.conf`) |

## How it fits together

bootc treats the OS as an OCI container image. The running system is a
checked-out, immutable view of that image. bdfs-dwarfs adds two things:

1. **Mutable workspaces** — `bdfs-bootc workspace` creates a writable overlay
   on top of the live bootc root so you can test changes without rebooting.

2. **Round-trip through DwarFS** — `bdfs-bootc export` packs the live root
   into a compressed DwarFS image for archival, transfer, or offline analysis.

```
bootc image (OCI)
      │
      └──checkout──► live root (immutable)
                          │
                          └──bdfs-bootc workspace──► writable workspace
                                                          │
                          ┌───────────────────────────────┘
                          │
                          ├──bdfs-bootc commit──► new OCI image ──► registry
                          └──bdfs-bootc export──► DwarFS image
```

## Install

```bash
install -m 755 bdfs-bootc.sh /usr/local/bin/bdfs-bootc
install -m 644 bdfs-bootc.conf /etc/bdfs/bootc.conf
```

## Usage

```bash
# Create a mutable workspace on top of the live bootc root
bdfs-bootc workspace --name my-experiment

# Work in the workspace
bdfs dev shell my-experiment

# Build a new OCI image from the workspace and push it
bdfs-bootc commit my-experiment \
    --image quay.io/myorg/myos:dev \
    --push

# Switch the system to the new image (staged, activates on reboot)
bdfs-bootc switch --image quay.io/myorg/myos:dev

# Check for upstream upgrades without applying
bdfs-bootc upgrade --check

# Apply upgrade (staged)
bdfs-bootc upgrade

# Export the live root as a DwarFS image
bdfs-bootc export --out /var/lib/bdfs/myos-$(date +%Y%m%d).dwarfs

# Show bootc status and active bdfs workspaces
bdfs-bootc status
```

## Dependencies

- `bootc` — `dnf install bootc` / build from [source](https://github.com/bootc-dev/bootc)
- `bdfs` — btrfs-dwarfs-framework
- `podman` — for `commit` (building OCI images)
- `mkdwarfs` / `dwarfs` — for `export`

## Relationship to the OSTree integration

bootc uses OSTree internally for deployment management. The
[OSTree integration](../ostree/README.md) operates at the OSTree layer
(repos, refs, deployments). This integration operates at the bootc layer
(OCI images, `bootc switch`, `bootc upgrade`). Use whichever matches your
workflow — they are independent.

## Supported systems

Any system running bootc. As of 2026, this includes:
- Fedora CoreOS / Silverblue / Kinoite (via `rpm-ostree` + bootc)
- CentOS Stream / RHEL with bootc enabled
- Any custom bootc-based image built with `FROM quay.io/centos-bootc/centos-bootc`
