# ipfs/dwarfs-pin

Pins DwarFS archives produced by `bdfs demote` to IPFS, making evicted
artifacts and demoted LFS snapshots retrievable by CID from any IPFS node.

## Why CAR streaming, not raw Add

DwarFS archives can be multi-gigabyte. The Kubo HTTP API's `/api/v0/add`
endpoint accepts a raw file stream, but for large files the preferred approach
is to chunk the content into a CAR (Content Addressable aRchive) before
adding. This is the same pattern used by `ipgit` and `tools/linux2ipfs` in
this repository.

`dwarfs-pin` uses chunked CAR streaming via the Kubo `/api/v0/dag/import`
endpoint:

1. The `.dwarfs` file is read in fixed-size chunks (default 256 KiB).
2. Each chunk is wrapped as a raw IPFS block and assembled into a CAR.
3. The CAR is streamed to `/api/v0/dag/import` in a single HTTP request.
4. The root CID returned by Kubo is pinned via `/api/v0/pin/add`.
5. The path → CID mapping is recorded in a local SQLite index.

This approach is:
- **Resumable** — if the stream is interrupted, only the CAR needs to be
  re-sent; the index records whether a path is already pinned.
- **Deduplicating** — IPFS deduplicates blocks by CID, so identical chunks
  across archives are stored once.
- **Memory-bounded** — the file is never fully loaded into memory.

## Architecture

```
bdfs demote → <path>.dwarfs
                    │
                    ▼
            dwarfs-pin.Pinner.Pin(ctx, archivePath)
                    │
          ┌─────────┴──────────┐
          │                    │
    already in index?     stream as CAR
    return cached CID     to Kubo dag/import
                                │
                          pin/add root CID
                                │
                          record path→CID
                          in SQLite index
```

## Integration points

| Caller | When |
|---|---|
| `bandwidth/bdfs.go` `evictArtifactFile` | After successful `bdfs demote` of a CI artifact |
| `lfs/adapters/bdfs/bdfs.go` `Demote()` | After successful `bdfs demote` of the LFS store |

Both callers receive a `*Pinner` (or `nil` when IPFS is not configured) and
call `Pin(ctx, archivePath)`. A nil Pinner is a no-op, so callers require no
conditional logic.

## Configuration

```yaml
# config/local.yaml
ipfs:
  enabled: true
  node: "http://127.0.0.1:5001"   # Kubo HTTP API

  dwarfs_pin:
    enabled: false          # opt-in; set true to pin .dwarfs archives
    chunk_size_kb: 256      # CAR chunk size in KiB
    index_path: ""          # SQLite index; defaults to /var/lib/gitlab-enhanced/dwarfs-pin.db
```

Environment variable overrides:

| Variable | Field |
|---|---|
| `GITLAB_ENHANCED_IPFS_DWARFS_PIN_ENABLED` | `dwarfs_pin.enabled` |
| `GITLAB_ENHANCED_IPFS_DWARFS_PIN_CHUNK_SIZE_KB` | `dwarfs_pin.chunk_size_kb` |
| `GITLAB_ENHANCED_IPFS_DWARFS_PIN_INDEX_PATH` | `dwarfs_pin.index_path` |

## Fallback behaviour

- When `ipfs.enabled` is false or `dwarfs_pin.enabled` is false, `Pin` is a
  no-op returning `nil`.
- When the Kubo node is unreachable, `Pin` returns an error. Callers log and
  continue — a failed pin does not prevent artifact eviction or LFS demote.
- When a path is already in the index, `Pin` returns the cached CID without
  contacting Kubo.

## Retrieving a pinned archive

```bash
# Retrieve by CID and restore the subvolume
ipfs get <CID> -o lfs-store.dwarfs
bdfs promote --image-name lfs-store.dwarfs --blend-path /var/lib/gitlab-enhanced/lfs
```

The CID for a given archive path is available via the index:

```bash
gitlab-enhanced ipfs dwarfs-pin stat <archive-path>
```
