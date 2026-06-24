# Dev Container Integration

Bridges the [Dev Container spec](https://containers.dev) with
btrfs-dwarfs-framework's snapshot and workspace capabilities.

Dev containers define a full development environment as a container image
plus a `devcontainer.json` configuration. This integration adds bdfs-powered
snapshotting, DwarFS archival, and offline image distribution on top of the
standard `devcontainer` CLI workflow.

## What this provides

| Script | Purpose |
|---|---|
| `bdfs-devcontainer.sh` | CLI: snapshot, export, import, build, up, status |
| `bdfs-devcontainer.conf` | Site configuration (copy to `/etc/bdfs/devcontainer.conf`) |

## How it fits together

```
devcontainer.json
      │
      └──bdfs-devcontainer up ──► running container
                                        │
                          ┌─────────────┘
                          │
                          ├──bdfs-devcontainer snapshot──► bdfs workspace
                          │                                    (writable, inspectable)
                          └──bdfs-devcontainer export──► DwarFS archive
                                                              │
                                          bdfs-devcontainer import──► container image
                                                                            │
                                                              devcontainer up (offline)
```

## Install

```bash
install -m 755 bdfs-devcontainer.sh /usr/local/bin/bdfs-devcontainer
install -m 644 bdfs-devcontainer.conf /etc/bdfs/devcontainer.conf
```

## Usage

```bash
# Start a dev container with a pre-snapshot of the workspace root
bdfs-devcontainer up --workspace-folder ./my-project --snapshot

# Snapshot a running dev container's filesystem into a bdfs workspace
bdfs-devcontainer snapshot --name my-devcontainer-snapshot

# Inspect or modify the snapshot
bdfs dev shell my-devcontainer-snapshot

# Export the running container's rootfs as a DwarFS archive
bdfs-devcontainer export \
    --container <id> \
    --out /var/lib/bdfs/devcontainer-images/my-project-$(date +%Y%m%d).dwarfs

# Import a DwarFS archive as a container image (for offline/air-gapped use)
bdfs-devcontainer import \
    /var/lib/bdfs/devcontainer-images/my-project-20260525.dwarfs \
    --tag my-project-devcontainer:20260525

# Reference the imported image in devcontainer.json:
#   { "image": "my-project-devcontainer:20260525" }

# Build the dev container image and pack it as DwarFS in one step
bdfs-devcontainer build \
    --workspace-folder ./my-project \
    --pack \
    --out /var/lib/bdfs/devcontainer-images/my-project-built.dwarfs

# Show running dev containers and active bdfs workspaces
bdfs-devcontainer status
```

## Dependencies

- `devcontainer` CLI — [install script](https://github.com/devcontainers/cli#install-script)
  or `npm install -g @devcontainers/cli`
- `bdfs` — btrfs-dwarfs-framework
- `docker` or `podman` — container runtime
- `mkdwarfs` / `dwarfs` — for export/import/build --pack
- `fuse` — for import (mounts DwarFS image during `docker import`)

## Key use cases

**Offline / air-gapped environments** — build the dev container image once,
export it as a DwarFS archive, transfer it, import it on the target machine.
No registry required.

**Reproducible snapshots** — `bdfs-devcontainer up --snapshot` takes a
point-in-time snapshot of the workspace root before starting the container,
so you can always roll back to the pre-container state.

**Forensic inspection** — `snapshot` captures the live container filesystem
into a bdfs workspace, letting you inspect or diff the container state without
stopping it.

## Relationship to the devcontainers submodules (PR #2)

[PR #2](../../) adds the upstream `devcontainers/*` repos as git submodules
under `integrations/devcontainers-*`. This integration (`integrations/devcontainer/`)
is the bdfs-side tooling that *uses* those repos' outputs (images, features,
templates). They are complementary — the submodules track upstream source,
this directory provides the bdfs integration scripts.
