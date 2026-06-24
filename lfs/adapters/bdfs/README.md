# lfs/adapters/bdfs

Storage lifecycle management for the LFS object store, backed by
btr-fs-git (BFG) and btrfs-dwarfs-framework (bdfs).

This adapter does **not** replace the LFS server (rudolfs, giftless, etc.).
It sits alongside it and manages the *filesystem* that the server's
`StoragePath` lives on:

```
git-lfs client
      │
      ▼
 LFS server (rudolfs / giftless / lfs-test-server)
      │  reads/writes objects at cfg.LFS.Path
      ▼
 BTRFS subvolume  ◄── managed by btr-fs-git (BFG)
      │
      ▼
 DwarFS archive   ◄── produced by bdfs demote (cold storage)
```

## What it provides

### `StorageLifecycle`

The single exported type. Constructed from `Config` and exposes three
operations, each a thin subprocess call with graceful fallback:

| Method | Tool called | When |
|---|---|---|
| `Snapshot()` | `bfg local_commit` | Before LFS server starts (pre-serve) |
| `Demote(compression)` | `bdfs demote` | On demand or scheduled |
| `Prune(keep, pattern)` | `bdfs snapshot prune` | On demand or scheduled |

All three are no-ops (returning `nil`) when the required binary is absent,
so the LFS server works normally on hosts without btr-fs-git or bdfs.

## Integration points

### A — adapter (this package)

`StorageLifecycle` is the reusable primitive. Any code that has a
`cfg.LFS.Path` can construct one and call its methods.

### B — CLI lifecycle hooks (`cmd/gitlab-enhanced/cmd_lfs.go`)

`lfs serve` calls `StorageLifecycle.Snapshot()` before starting the server
process, giving a clean recovery point before any new objects are written.
On shutdown (after the server exits), it calls `Prune` if
`lfs.bdfs_prune_keep` is set.

```
gitlab-enhanced lfs serve
  │
  ├─ StorageLifecycle.Snapshot()   ← pre-serve commit via bfg
  │
  ├─ runRudolfs / runGiftless / runLFSTestServer  (blocks)
  │
  └─ StorageLifecycle.Prune(keep, pattern)  ← post-serve prune via bdfs
```

## Configuration

All fields are under `lfs:` in `config/local.yaml`:

```yaml
lfs:
  path: /var/lib/gitlab-enhanced/lfs

  # btr-fs-git integration — snapshot the LFS store before each serve.
  # Requires bfg to be installed and lfs.path to be a BTRFS subvolume.
  bdfs_snapshot_on_serve: false

  # bdfs snapshot prune — run after lfs serve exits.
  # 0 = disabled. Requires bdfs to be installed.
  bdfs_prune_keep: 0

  # Name pattern passed to bdfs snapshot prune --pattern.
  # Empty = match all snapshots under lfs.path.
  bdfs_prune_pattern: ""

  # Compression algorithm for bdfs demote (zstd | lzma | lz4 | brotli | none).
  bdfs_compression: zstd
```

All fields are also settable via environment variables:

| Variable | Field |
|---|---|
| `GITLAB_ENHANCED_LFS_BDFS_SNAPSHOT_ON_SERVE` | `bdfs_snapshot_on_serve` |
| `GITLAB_ENHANCED_LFS_BDFS_PRUNE_KEEP` | `bdfs_prune_keep` |
| `GITLAB_ENHANCED_LFS_BDFS_PRUNE_PATTERN` | `bdfs_prune_pattern` |
| `GITLAB_ENHANCED_LFS_BDFS_COMPRESSION` | `bdfs_compression` |

## Requirements

- `lfs.path` must be a BTRFS subvolume (not a plain directory) for
  `Snapshot` and `Prune` to have any effect.
- `bfg` must be in `PATH` for `Snapshot`.
- `bdfs` must be in `PATH` for `Demote` and `Prune`.
- The bdfs daemon (`bdfs_daemon`) must be running for `Prune` (it
  communicates via the Unix socket at `/run/bdfs/bdfs.sock`).

When any of these conditions are not met, the relevant method logs a
debug message and returns `nil` — the LFS server is unaffected.

## Fallback behaviour

```
Snapshot()
  bfg in PATH?  yes → bfg local_commit <path>
                no  → log.Debug, return nil

Demote(compression)
  bdfs in PATH? yes → bdfs demote --blend-path <path>
                          --image-name <path>.dwarfs
                          --compression <compression>
                no  → log.Debug, return nil

Prune(keep, pattern)
  bdfs in PATH? yes → bdfs snapshot prune --btrfs-mount <path>
                          --keep <keep> [--pattern <pattern>]
                          --demote-first --compression <compression>
                no  → log.Debug, return nil
```

Non-zero exit from any subprocess is returned as an error but does **not**
prevent the LFS server from starting or stopping — callers log and continue.
