/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * btrfs_dwarfs/types.h - Shared type definitions for the BTRFS+DwarFS framework
 *
 * The framework blends two complementary filesystem technologies:
 *   - BTRFS: mutable, CoW, snapshot/subvolume-capable block filesystem
 *   - DwarFS: read-only, highly-compressed FUSE filesystem (image-based)
 *
 * A "hybrid partition" is either:
 *   BDFS_PART_DWARFS_BACKED  - DwarFS image stores BTRFS subvolume/snapshot data
 *   BDFS_PART_BTRFS_BACKED   - BTRFS filesystem stores DwarFS image files
 *
 * The blend layer presents a unified namespace over both partition types.
 */

#ifndef _BTRFS_DWARFS_TYPES_H
#define _BTRFS_DWARFS_TYPES_H

#include <linux/types.h>
#include <linux/uuid.h>

/* Magic number embedded in the superblock of hybrid partitions */
#define BDFS_MAGIC              0xBD75F530UL
#define BDFS_VERSION_MAJOR      1
#define BDFS_VERSION_MINOR      0

/* Maximum lengths */
#define BDFS_NAME_MAX           255
#define BDFS_PATH_MAX           4096
#define BDFS_LABEL_MAX          256
#define BDFS_MAX_PARTITIONS     64
#define BDFS_MAX_DWARFS_IMAGES  1024

/*
 * Partition backing type.
 *
 * DWARFS_BACKED: The partition is a DwarFS image file. BTRFS subvolumes and
 *   snapshots are serialised into DwarFS images stored within it. Provides
 *   extreme compression for archival/read-mostly workloads.
 *
 * BTRFS_BACKED: The partition is a live BTRFS filesystem. DwarFS image files
 *   are stored as regular files on it, benefiting from CoW, checksumming, and
 *   snapshot semantics around the images themselves.
 */
enum bdfs_partition_type {
	BDFS_PART_UNKNOWN        = 0,
	BDFS_PART_DWARFS_BACKED  = 1,  /* DwarFS image holds btrfs data */
	BDFS_PART_BTRFS_BACKED   = 2,  /* BTRFS holds DwarFS image files */
	BDFS_PART_HYBRID_BLEND   = 3,  /* Both layers active, unified view */
};

/* DwarFS compression algorithm identifiers (mirrors dwarfs internal enum) */
enum bdfs_dwarfs_compression {
	BDFS_COMPRESS_NONE   = 0,
	BDFS_COMPRESS_LZMA   = 1,
	BDFS_COMPRESS_ZSTD   = 2,
	BDFS_COMPRESS_LZ4    = 3,
	BDFS_COMPRESS_BROTLI = 4,
};

/* BTRFS subvolume/snapshot descriptor as seen by the framework */
struct bdfs_btrfs_subvol {
	__u64   subvol_id;
	__u64   parent_id;
	__u64   generation;
	__u64   ctransid;           /* generation when last changed */
	__u64   otransid;           /* generation when created */
	__u64   stransid;           /* generation of the send root */
	__u64   rtransid;           /* generation of the receive root */
	__u8    uuid[16];
	__u8    parent_uuid[16];
	__u8    received_uuid[16];
	__u64   flags;
	char    name[BDFS_NAME_MAX + 1];
	char    path[BDFS_PATH_MAX];
	__u8    is_snapshot;
	__u8    is_readonly;
	__u8    _pad[6];
};

/* DwarFS image descriptor */
struct bdfs_dwarfs_image {
	__u64   image_id;
	__u64   size_bytes;
	__u64   uncompressed_bytes;
	__u64   inode_count;
	__u64   block_count;
	__u32   schema_version;
	__u32   compression;        /* enum bdfs_dwarfs_compression */
	__u8    uuid[16];
	char    name[BDFS_NAME_MAX + 1];
	char    backing_path[BDFS_PATH_MAX]; /* path on BTRFS or block device */
	__u8    mounted;
	char    mount_point[BDFS_PATH_MAX];
	__u8    _pad[7];
};

/* Per-partition descriptor stored in the framework registry */
struct bdfs_partition {
	__u32   magic;              /* BDFS_MAGIC */
	__u16   version_major;
	__u16   version_minor;
	__u32   type;               /* enum bdfs_partition_type */
	__u32   flags;
	__u8    uuid[16];
	char    label[BDFS_LABEL_MAX];
	char    device_path[BDFS_PATH_MAX];
	char    mount_point[BDFS_PATH_MAX];

	/* BTRFS-specific fields (valid when type includes BTRFS) */
	__u64   btrfs_fsid[2];
	__u64   btrfs_subvol_count;
	__u64   btrfs_snapshot_count;

	/* DwarFS-specific fields (valid when type includes DWARFS) */
	__u64   dwarfs_image_count;
	__u32   dwarfs_default_compression;
	__u32   dwarfs_block_size_bits;     /* log2 of block size */

	/* Blend layer fields (valid for HYBRID_BLEND) */
	__u8    blend_btrfs_uuid[16];       /* UUID of the BTRFS side */
	__u8    blend_dwarfs_uuid[16];      /* UUID of the DwarFS side */
	char    blend_mount_point[BDFS_PATH_MAX];
};

/* Mount options passed to the blend layer */
struct bdfs_mount_opts {
	__u32   flags;
#define BDFS_MOUNT_RDONLY        (1 << 0)
#define BDFS_MOUNT_COMPRESS      (1 << 1)
#define BDFS_MOUNT_NODATACOW     (1 << 2)
#define BDFS_MOUNT_AUTOSNAP      (1 << 3)  /* auto-snapshot on dwarfs export */
#define BDFS_MOUNT_LAZY_LOAD     (1 << 4)  /* defer dwarfs image mount */
#define BDFS_MOUNT_WRITEBACK     (1 << 5)  /* allow writes via btrfs side */
	__u32   compression;
	__u32   block_size_bits;
	__u32   cache_size_mb;
	__u32   worker_threads;
	__u32   _pad;
};

/* Event types emitted by the framework to userspace via netlink/uevent */
enum bdfs_event_type {
	BDFS_EVT_PARTITION_ADDED    = 1,
	BDFS_EVT_PARTITION_REMOVED  = 2,
	BDFS_EVT_SNAPSHOT_CREATED   = 3,
	BDFS_EVT_SNAPSHOT_EXPORTED  = 4,  /* btrfs snapshot → dwarfs image */
	BDFS_EVT_IMAGE_IMPORTED     = 5,  /* dwarfs image → btrfs subvol */
	BDFS_EVT_IMAGE_MOUNTED      = 6,
	BDFS_EVT_IMAGE_UNMOUNTED    = 7,
	BDFS_EVT_BLEND_MOUNTED      = 8,
	BDFS_EVT_BLEND_UNMOUNTED    = 9,
	/*
	 * Emitted by bdfs_blend_open() when a write-mode open is attempted
	 * on a DwarFS lower-layer inode.  The daemon must copy the file to
	 * the BTRFS upper layer and call BDFS_IOC_COPYUP_COMPLETE.
	 * message format: "copyup_needed lower=<path> upper=<path>"
	 * object_id: blend inode number
	 * partition_uuid: BTRFS upper layer UUID
	 */
	BDFS_EVT_COPYUP_NEEDED      = 10,
	BDFS_EVT_ERROR              = 255,
};

struct bdfs_event {
	__u32   type;               /* enum bdfs_event_type */
	__u32   flags;
	__u8    partition_uuid[16];
	__u64   object_id;          /* subvol_id or image_id depending on type */
	char    message[256];
	__u64   timestamp_ns;
};

#endif /* _BTRFS_DWARFS_TYPES_H */
