# OSTree Integration

Bridges [OSTree](https://github.com/ostreedev/ostree)'s immutable deployment
model with btrfs-dwarfs-framework's snapshot and workspace capabilities.

## What this provides

| Script | Purpose |
|---|---|
| `bdfs-ostree.sh` | CLI wrapper: commit, publish, export, import, prune, status |
| `bdfs-ostree.conf` | Site configuration (copy to `/etc/bdfs/ostree.conf`) |
| `bdfs-ostree-prune.service` | systemd unit — prune old deployments after upgrade |
| `bdfs-ostree-prune.timer` | systemd timer — triggers prune on `ostree-finalize-staged` |

## How it fits together

```
OSTree repo  ←──commit──  bdfs workspace  ←──create──  OSTree deployment root
     │                          │
     └──export──►  DwarFS image  ◄──import──┘
```

`bdfs dev` already auto-detects OSTree deployment roots (presence of
`.ostree-deployment` or the `usr/`+`etc`-symlink layout) and takes a
consistent read-only snapshot before creating a writable workspace. This
integration adds the reverse path: committing workspace changes back to OSTree
and round-tripping through DwarFS images.

## Install

```bash
# Install the CLI
install -m 755 bdfs-ostree.sh /usr/local/bin/bdfs-ostree

# Install site config
install -m 644 bdfs-ostree.conf /etc/bdfs/ostree.conf
# Edit /etc/bdfs/ostree.conf — set BDFS_OSTREE_REPO and BDFS_OSTREE_BRANCH

# Install systemd units (optional — auto-prune after upgrades)
install -m 644 bdfs-ostree-prune.service /etc/systemd/system/
install -m 644 bdfs-ostree-prune.timer   /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now bdfs-ostree-prune.timer
```

## Usage

```bash
# Create a mutable workspace on top of the current OSTree deployment
bdfs dev create my-workspace --source /ostree/deploy/default/deploy/<hash>

# Work in the workspace
bdfs dev shell my-workspace

# Commit changes back to OSTree
bdfs-ostree commit my-workspace --repo /ostree/repo --branch myos/dev

# Deploy (active on next boot)
bdfs-ostree publish my-workspace --repo /ostree/repo --branch myos/stable

# Export an OSTree commit as a DwarFS image
bdfs-ostree export myos/stable --repo /ostree/repo --out /var/lib/bdfs/myos-stable.dwarfs

# Import a DwarFS image into OSTree
bdfs-ostree import /var/lib/bdfs/myos-stable.dwarfs --repo /ostree/repo --branch myos/imported

# Prune old deployments (keep 3)
bdfs-ostree prune --repo /ostree/repo --keep 3

# Show deployment status
bdfs-ostree status --repo /ostree/repo
```

## Dependencies

- `ostree` (libostree) — `dnf install ostree` / `apt install ostree`
- `bdfs` — btrfs-dwarfs-framework
- `mkdwarfs` / `dwarfs` — for export/import subcommands
- `fuse` — for import (mounts DwarFS image during commit)

## Distros with native OSTree support

| Distro | Stack |
|---|---|
| Fedora Silverblue / Kinoite | rpm-ostree + OSTree |
| Fedora CoreOS | rpm-ostree + OSTree |
| EndlessOS | OSTree (custom) |
| GNOME OS | OSTree |
| Any via `ostree init` | bare OSTree repo |

## Relationship to `bdfs dev`

`bdfs dev` handles the *workspace* side (create, shell, status, drop).
`bdfs-ostree` handles the *OSTree* side (commit, deploy, export, import).
They are complementary — `bdfs dev` does not require OSTree, and
`bdfs-ostree` does not require `bdfs dev` (you can point it at any directory).
