/* SPDX-License-Identifier: GPL-2.0-or-later WITH Linux-syscall-note */
/*
 * uapi/bdfs_ioctl.h - IOCTL interface between userspace tools and the
 * BTRFS+DwarFS kernel module / userspace daemon.
 *
 * All ioctls go through the control device /dev/bdfs_ctl.
 * Partition-specific ioctls go through /dev/bdfs/<uuid>.
 */
#ifndef _UAPI_BDFS_IOCTL_H
#define _UAPI_BDFS_IOCTL_H

#include <linux/ioctl.h>
#include <linux/types.h>
#include "btrfs_dwarfs/types.h"

#define BDFS_IOCTL_MAGIC 0xBD

/* ── Global control device ioctls (/dev/bdfs_ctl) ─────────────────────── */

/* Register a new partition with the framework */
struct bdfs_ioctl_register_partition {
	struct bdfs_partition part; /* in: partition descriptor */
	__u8 uuid_out[16];          /* out: assigned UUID */
};
#define BDFS_IOC_REGISTER_PARTITION \
	_IOWR(BDFS_IOCTL_MAGIC, 0x01, struct bdfs_ioctl_register_partition)

/* Unregister a partition */
struct bdfs_ioctl_unregister_partition {
	__u8 uuid[16];
};
#define BDFS_IOC_UNREGISTER_PARTITION \
	_IOW(BDFS_IOCTL_MAGIC, 0x02, struct bdfs_ioctl_unregister_partition)

/* List registered partitions */
struct bdfs_ioctl_list_partitions {
	__u32 count;              /* in: capacity of parts[]; out: actual */
	__u32 total;              /* out: total partitions registered */
	struct bdfs_partition *parts; /* in: pointer to caller buffer */
};
#define BDFS_IOC_LIST_PARTITIONS \
	_IOWR(BDFS_IOCTL_MAGIC, 0x03, struct bdfs_ioctl_list_partitions)

/* Mount the blend layer over a BTRFS+DwarFS partition pair */
struct bdfs_ioctl_mount_blend {
	__u8 btrfs_uuid[16];
	__u8 dwarfs_uuid[16];
	char mount_point[BDFS_PATH_MAX];
	struct bdfs_mount_opts opts;
};
#define BDFS_IOC_MOUNT_BLEND \
	_IOW(BDFS_IOCTL_MAGIC, 0x04, struct bdfs_ioctl_mount_blend)

/* Unmount the blend layer */
struct bdfs_ioctl_umount_blend {
	char mount_point[BDFS_PATH_MAX];
	__u32 flags;
#define BDFS_UMOUNT_FORCE (1 << 0)
#define BDFS_UMOUNT_LAZY  (1 << 1)
};
#define BDFS_IOC_UMOUNT_BLEND \
	_IOW(BDFS_IOCTL_MAGIC, 0x05, struct bdfs_ioctl_umount_blend)

/*
 * Mount the blend layer using fuse-overlayfs in userspace.
 *
 * Used when the bdfs_blend kernel module is unavailable (ENODEV) or when
 * --userspace is passed explicitly.  The daemon mounts the DwarFS image via
 * the dwarfs FUSE driver, then invokes fuse-overlayfs with:
 *
 *   lowerdir  = <dwarfs FUSE mount>
 *   upperdir  = btrfs_mount  (must be a BTRFS subvolume)
 *   workdir   = work_dir     (must be on the same BTRFS filesystem)
 *   merged    = mount_point
 *
 * The daemon tracks both the dwarfs FUSE mount and the fuse-overlayfs mount
 * so they are torn down in the correct order on umount.
 */
struct bdfs_ioctl_mount_blend_userspace {
	__u8  btrfs_uuid[16];
	__u8  dwarfs_uuid[16];
	char  mount_point[BDFS_PATH_MAX]; /* merged mountpoint */
	char  btrfs_mount[BDFS_PATH_MAX]; /* BTRFS upper subvolume path */
	char  dwarfs_image[BDFS_PATH_MAX];/* path to .dwarfs image file */
	char  work_dir[BDFS_PATH_MAX];    /* overlayfs workdir (same FS as upper) */
	__u32 cache_size_mb;              /* dwarfs FUSE cache size */
	__u32 flags;
#define BDFS_MOUNT_USERSPACE_OVERLAY (1 << 0) /* use fuse-overlayfs backend */
#define BDFS_MOUNT_WRITEBACK         (1 << 1) /* allow writes to upper layer */
};
#define BDFS_IOC_MOUNT_BLEND_USERSPACE \
	_IOW(BDFS_IOCTL_MAGIC, 0x06, struct bdfs_ioctl_mount_blend_userspace)

/*
 * BDFS_IOC_BLEND_ATTACH_MOUNTS — called by the daemon after it has mounted
 * the BTRFS upper layer and all DwarFS lower layers.  Passes open O_PATH
 * file descriptors for each vfsmount back to the kernel so the blend layer
 * can hold proper mntget() references and use them for VFS operations.
 *
 * The daemon opens each mount point with open(O_PATH) and passes the fd here.
 * The kernel calls fdget() to obtain the vfsmount, calls mntget(), then
 * releases the fd reference.  This avoids kern_mount() in the kernel and lets
 * the daemon control the actual mount lifecycle.
 *
 * dwarfs_fds[0..n_dwarfs-1] are the DwarFS FUSE mount fds in layer order.
 * n_dwarfs must be ≤ BDFS_MAX_DWARFS_LAYERS.
 */
#define BDFS_MAX_DWARFS_LAYERS  8

struct bdfs_ioctl_blend_attach_mounts {
	char  mount_point[BDFS_PATH_MAX]; /* identifies which bm to update */
	int   btrfs_fd;                   /* O_PATH fd for BTRFS upper mount */
	__u32 n_dwarfs;                   /* number of DwarFS layer fds */
	int   dwarfs_fds[BDFS_MAX_DWARFS_LAYERS]; /* O_PATH fds, in order */
};

#define BDFS_IOC_BLEND_ATTACH_MOUNTS \
	_IOW(BDFS_IOCTL_MAGIC, 0x07, struct bdfs_ioctl_blend_attach_mounts)

/*
 * BDFS_IOC_SETXATTR / BDFS_IOC_GETXATTR — set/get an xattr on a blend inode
 * by blend-namespace path.  Used by offline tooling that cannot use the
 * standard setxattr(2)/getxattr(2) syscalls directly on the blend mount.
 *
 * For normal in-kernel xattr operations on a mounted blend filesystem the
 * standard syscalls are routed through bdfs_blend_setxattr/getxattr
 * automatically via the s_xattr handler table — no ioctl needed.
 */
struct bdfs_ioctl_xattr {
	char  mount_point[BDFS_PATH_MAX]; /* blend mount point */
	char  path[BDFS_PATH_MAX];        /* path relative to blend mount */
	char  name[256];                  /* xattr name (e.g. "user.foo") */
	__u32 size;                       /* value buf size (in) / actual (out) */
	__u32 flags;                      /* XATTR_CREATE / XATTR_REPLACE (set) */
	__u8  value[65536];               /* value buffer */
};

#define BDFS_IOC_SETXATTR \
	_IOW(BDFS_IOCTL_MAGIC, 0x08, struct bdfs_ioctl_xattr)
#define BDFS_IOC_GETXATTR \
	_IOWR(BDFS_IOCTL_MAGIC, 0x09, struct bdfs_ioctl_xattr)

/* ── DwarFS-backed partition ioctls ────────────────────────────────────── */

/*
 * Export a BTRFS subvolume or snapshot into a DwarFS image stored on a
 * DwarFS-backed partition.  The source subvolume is read via send/receive
 * stream; the resulting DwarFS image is written to the backing store.
 */
struct bdfs_ioctl_export_to_dwarfs {
	__u8  partition_uuid[16];        /* target DwarFS-backed partition */
	__u64 btrfs_subvol_id;           /* source subvolume/snapshot id */
	char  btrfs_mount[BDFS_PATH_MAX];/* where the btrfs fs is mounted */
	char  image_name[BDFS_NAME_MAX + 1];
	__u32 compression;               /* enum bdfs_dwarfs_compression */
	__u32 block_size_bits;
	__u32 worker_threads;
	__u32 flags;
#define BDFS_EXPORT_INCREMENTAL (1 << 0) /* incremental from parent snap */
#define BDFS_EXPORT_VERIFY      (1 << 1) /* verify image after creation */
	/*
	 * Absolute path to the parent read-only snapshot for incremental
	 * export (btrfs send -p <parent>).  Required when
	 * BDFS_EXPORT_INCREMENTAL is set; ignored otherwise.
	 */
	char  parent_snap_path[BDFS_PATH_MAX];
	__u64 image_id_out;              /* out: assigned image id */
};
#define BDFS_IOC_EXPORT_TO_DWARFS \
	_IOWR(BDFS_IOCTL_MAGIC, 0x10, struct bdfs_ioctl_export_to_dwarfs)

/* Mount a DwarFS image from a DwarFS-backed partition */
struct bdfs_ioctl_mount_dwarfs_image {
	__u8  partition_uuid[16];
	__u64 image_id;
	char  mount_point[BDFS_PATH_MAX];
	__u32 flags;
#define BDFS_DWARFS_MOUNT_CACHE (1 << 0)
	__u32 cache_size_mb;
};
#define BDFS_IOC_MOUNT_DWARFS_IMAGE \
	_IOW(BDFS_IOCTL_MAGIC, 0x11, struct bdfs_ioctl_mount_dwarfs_image)

/* Unmount a DwarFS image */
struct bdfs_ioctl_umount_dwarfs_image {
	__u8  partition_uuid[16];
	__u64 image_id;
	__u32 flags;
};
#define BDFS_IOC_UMOUNT_DWARFS_IMAGE \
	_IOW(BDFS_IOCTL_MAGIC, 0x12, struct bdfs_ioctl_umount_dwarfs_image)

/* List DwarFS images on a DwarFS-backed partition */
struct bdfs_ioctl_list_dwarfs_images {
	__u8  partition_uuid[16];
	__u32 count;   /* in: capacity; out: actual */
	__u32 total;
	struct bdfs_dwarfs_image *images;
};
#define BDFS_IOC_LIST_DWARFS_IMAGES \
	_IOWR(BDFS_IOCTL_MAGIC, 0x13, struct bdfs_ioctl_list_dwarfs_images)

/* ── BTRFS-backed partition ioctls ─────────────────────────────────────── */

/*
 * Import a DwarFS image stored on a BTRFS-backed partition into a new
 * BTRFS subvolume.  The DwarFS image is extracted via dwarfsextract and
 * the result is received as a new subvolume on the target BTRFS filesystem.
 */
struct bdfs_ioctl_import_from_dwarfs {
	__u8  partition_uuid[16];        /* source BTRFS-backed partition */
	__u64 image_id;                  /* DwarFS image to import */
	char  btrfs_mount[BDFS_PATH_MAX];/* target btrfs filesystem */
	char  subvol_name[BDFS_NAME_MAX + 1];
	__u32 flags;
#define BDFS_IMPORT_READONLY (1 << 0)
#define BDFS_IMPORT_SNAPSHOT (1 << 1) /* create as snapshot */
	__u64 subvol_id_out;
};
#define BDFS_IOC_IMPORT_FROM_DWARFS \
	_IOWR(BDFS_IOCTL_MAGIC, 0x20, struct bdfs_ioctl_import_from_dwarfs)

/* Store a DwarFS image file onto a BTRFS-backed partition */
struct bdfs_ioctl_store_dwarfs_image {
	__u8  partition_uuid[16];
	char  source_path[BDFS_PATH_MAX]; /* path to .dwarfs file */
	char  dest_name[BDFS_NAME_MAX + 1];
	__u32 flags;
#define BDFS_STORE_COMPRESS_META (1 << 0) /* btrfs-compress the image file */
#define BDFS_STORE_SNAPSHOT      (1 << 1) /* take btrfs snapshot after store */
	__u64 image_id_out;
};
#define BDFS_IOC_STORE_DWARFS_IMAGE \
	_IOWR(BDFS_IOCTL_MAGIC, 0x21, struct bdfs_ioctl_store_dwarfs_image)

/* Create a BTRFS snapshot of the directory containing a DwarFS image */
struct bdfs_ioctl_snapshot_dwarfs_container {
	__u8  partition_uuid[16];
	__u64 image_id;
	char  snapshot_name[BDFS_NAME_MAX + 1];
	__u32 flags;
#define BDFS_SNAP_READONLY (1 << 0)
	__u64 snapshot_subvol_id_out;
};
#define BDFS_IOC_SNAPSHOT_DWARFS_CONTAINER \
	_IOWR(BDFS_IOCTL_MAGIC, 0x22, struct bdfs_ioctl_snapshot_dwarfs_container)

/* List BTRFS subvolumes/snapshots on a BTRFS-backed partition */
struct bdfs_ioctl_list_btrfs_subvols {
	__u8  partition_uuid[16];
	__u32 count;
	__u32 total;
	struct bdfs_btrfs_subvol *subvols;
};
#define BDFS_IOC_LIST_BTRFS_SUBVOLS \
	_IOWR(BDFS_IOCTL_MAGIC, 0x23, struct bdfs_ioctl_list_btrfs_subvols)

/* ── Blend layer ioctls (on mounted blend point) ───────────────────────── */

/* Resolve a path in the blend namespace to its backing layer */
struct bdfs_ioctl_resolve_path {
	char  path[BDFS_PATH_MAX];      /* in: path within blend mount */
	__u32 layer;                    /* out: 0=btrfs, 1=dwarfs, 2=both */
	char  real_path[BDFS_PATH_MAX]; /* out: real path on backing layer */
	__u64 object_id;                /* out: subvol_id or image_id */
};
#define BDFS_IOC_RESOLVE_PATH \
	_IOWR(BDFS_IOCTL_MAGIC, 0x30, struct bdfs_ioctl_resolve_path)

/* Promote a DwarFS-backed path to a writable BTRFS subvolume */
struct bdfs_ioctl_promote_to_btrfs {
	char  blend_path[BDFS_PATH_MAX];
	char  subvol_name[BDFS_NAME_MAX + 1];
	__u32 flags;
	__u64 subvol_id_out;
};
#define BDFS_IOC_PROMOTE_TO_BTRFS \
	_IOWR(BDFS_IOCTL_MAGIC, 0x31, struct bdfs_ioctl_promote_to_btrfs)

/* Demote a BTRFS subvolume to a DwarFS image (archive/compress) */
struct bdfs_ioctl_demote_to_dwarfs {
	char  blend_path[BDFS_PATH_MAX];
	char  image_name[BDFS_NAME_MAX + 1];
	__u32 compression;
	__u32 flags;
#define BDFS_DEMOTE_DELETE_SUBVOL (1 << 0) /* remove btrfs subvol after */
	__u64 image_id_out;
};
#define BDFS_IOC_DEMOTE_TO_DWARFS \
	_IOWR(BDFS_IOCTL_MAGIC, 0x32, struct bdfs_ioctl_demote_to_dwarfs)

/*
 * Signal copy-up completion to the kernel.  Called by the daemon after it
 * has promoted a DwarFS-backed file to the BTRFS upper layer.  The kernel
 * wakes any threads blocked in bdfs_blend_open() waiting for this inode.
 */
struct bdfs_ioctl_copyup_complete {
	__u8  btrfs_uuid[16];           /* blend mount's BTRFS partition UUID */
	__u64 inode_no;                 /* blend inode number being promoted */
	char  upper_path[BDFS_PATH_MAX];/* new path on BTRFS upper layer */
};
#define BDFS_IOC_COPYUP_COMPLETE \
	_IOW(BDFS_IOCTL_MAGIC, 0x40, struct bdfs_ioctl_copyup_complete)

#endif /* _UAPI_BDFS_IOCTL_H */
