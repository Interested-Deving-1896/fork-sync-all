# bdfs dev — Mutable Development Workspaces

`bdfs dev` creates writable workspaces on top of immutable filesystem roots.
It is backend-agnostic: the same subcommands work regardless of whether the
underlying root is a BTRFS subvolume, a DwarFS archive, or a plain directory.
OSTree integration is optional and auto-detected.

## Backends

### btrfs (default)

Creates a BTRFS writable snapshot of the source path. Requires the source to
be on a BTRFS filesystem. Changes are persistent and CoW-efficient. The
snapshot can be committed back to an OSTree repository or archived as a DwarFS
image.

Best for: OSTree deployment roots, long-running development, anything you want
to commit or archive.

### overlay

Creates an overlayfs workspace with the source as the read-only lower layer
and a tmpfs (or user-provided directory) as the writable upper layer. Works on
any filesystem. Changes are ephemeral by default — lost on `bdfs dev drop`
unless saved via `--upper PATH`, `bdfs dev commit`, or `bdfs dev demote`.

Best for: quick experiments, CI environments, systems without BTRFS.

### dwarfs

Mounts a DwarFS image read-only as the lower layer, adds a writable upper
layer (BTRFS subvolume if available, tmpfs otherwise) via overlayfs. Allows
working on compressed/archived roots without full extraction.

Best for: working on archived system states, storage-constrained environments.

## OSTree Integration

OSTree integration is optional. When `--ostree-repo` is provided (or
`BDFS_OSTREE_REPO` is set), two additional subcommands become meaningful:

- `bdfs dev commit` — runs `ostree commit --tree=dir=<mountpoint>` to record
  the workspace state as a new commit on a branch.
- `bdfs dev publish` — commits and then runs `ostree admin deploy` to make the
  new commit the active deployment on next boot.

OSTree's immutability requirement (hardlinked checkouts must not be modified
in place) is respected: `bdfs dev` never modifies the source deployment root.
It always works on a snapshot or overlay copy.

### Detecting OSTree deployment roots

The BTRFS backend auto-detects OSTree deployment roots by checking for:
- `.ostree-deployment` file in the root
- `usr/lib/os-release` present with `etc` as a symlink (OSTree's `/etc` merge)

When detected, a read-only snapshot is taken first for consistency before
creating the writable snapshot.

## Workflow Examples

### Feature development on an OSTree system

```sh
# Find the current deployment hash
HASH=$(ostree admin status | grep '* ' | awk '{print $2}')
DEPLOY="/ostree/deploy/default/deploy/${HASH}"

# Create a mutable workspace
bdfs dev create \
    --name my-feature \
    --source "$DEPLOY" \
    --backend btrfs \
    --ostree-repo /ostree/repo \
    --ostree-branch dev/my-feature

# Enter and make changes
bdfs dev shell my-feature
# (inside chroot)
dnf install -y strace
echo "debug=1" >> /etc/myapp.conf
exit

# Commit back to OSTree
bdfs dev commit my-feature --message "add debug tooling"

# Deploy on next boot
bdfs dev publish my-feature

# Clean up workspace
bdfs dev drop my-feature
```

### Quick ephemeral test (no BTRFS needed)

```sh
bdfs dev create \
    --name quick-test \
    --source /path/to/rootfs \
    --backend overlay \
    --tmpfs-size 1G

bdfs dev shell quick-test -- dnf install -y htop

# Changes are discarded on drop
bdfs dev drop quick-test --force
```

### Work on a compressed archive

```sh
bdfs dev create \
    --name archived-work \
    --source /path/to/snapshot.dwarfs \
    --backend dwarfs \
    --tmpfs-size 4G

bdfs dev shell archived-work

# Save changes as a new DwarFS image
bdfs dev demote archived-work --keep

# Or commit to OSTree
bdfs dev commit archived-work \
    --ostree-repo /ostree/repo \
    --ostree-branch archive/restored

bdfs dev drop archived-work
```

### Persist upper layer changes to a directory

```sh
bdfs dev create \
    --name persistent-overlay \
    --source /path/to/rootfs \
    --backend overlay \
    --upper /mnt/changes/my-overlay

bdfs dev shell persistent-overlay

# Changes survive drop — they're in /mnt/changes/my-overlay
bdfs dev drop persistent-overlay --force
```

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `BDFS_STATE_DIR` | `/var/lib/bdfs/dev` | Workspace metadata directory |
| `BDFS_OSTREE_REPO` | (none) | Default OSTree repository path |
| `BDFS_BTRFS_MOUNT` | (auto-detect) | BTRFS mount for snapshot storage |

## Exit Codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Usage error |
| 2 | Workspace not found |
| 3 | Backend error (BTRFS, overlayfs, DwarFS) |
| 4 | OSTree error |
| 5 | Missing dependency |
