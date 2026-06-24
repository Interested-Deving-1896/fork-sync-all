/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * bdfs_daemon.h - BTRFS+DwarFS userspace daemon internal API
 *
 * The daemon bridges the kernel module and the userspace tools
 * (mkdwarfs, dwarfs, dwarfsextract, btrfs-progs).  It:
 *
 * 1. Listens on the bdfs netlink socket for kernel-emitted events.
 * 2. Executes the appropriate tool pipeline for each event.
 * 3. Reports completion back to the kernel via /dev/bdfs_ctl ioctls.
 * 4. Manages FUSE mount lifecycles for DwarFS images.
 * 5. Exposes a Unix domain socket for the bdfs CLI tool.
 */
#ifndef _BDFS_DAEMON_H
#define _BDFS_DAEMON_H

#include <stdbool.h>
#include <stdint.h>
#include <pthread.h>
#include <sys/queue.h>
#include <syslog.h>

#include "../../include/uapi/bdfs_ioctl.h"

/* Daemon configuration */
struct bdfs_daemon_config {
	char ctl_device[256];        /* default: /dev/bdfs_ctl */
	char socket_path[256];       /* default: /run/bdfs/daemon.sock */
	char state_dir[256];         /* default: /var/lib/bdfs */
	char mkdwarfs_bin[256];
	char dwarfs_bin[256];
	char dwarfsextract_bin[256];
	char dwarfsck_bin[256];
	/*
	 * mkdwarfs_timeout_s — max seconds for a mkdwarfs child before
	 * SIGTERM then SIGKILL. 0 = compiled-in default (2700 s = 45 min).
	 * Set via bdfs.conf [daemon] mkdwarfs_timeout = <seconds>
	 */
	int  mkdwarfs_timeout_s;
	/*
	 * shutdown_log_path — append-only JSONL file for workspace shutdown
	 * events. Default: /var/log/bdfs/workspace-shutdown.jsonl
	 * Set via bdfs.conf [daemon] shutdown_log = <path>
	 */
	char shutdown_log_path[256];
	/*
	 * pin_helper_bin — path to bdfs-pin-helper binary.
	 * When empty the daemon searches $PATH for "bdfs-pin-helper".
	 * Set via bdfs.conf [tools] pin_helper = <path>
	 */
	char pin_helper_bin[256];
	/*
	 * kubo_api — Kubo HTTP RPC API base URL used by bdfs-pin-helper.
	 * Default: http://127.0.0.1:5001
	 * Set via bdfs.conf [daemon] kubo_api = <url>
	 */
	char kubo_api[256];
	char btrfs_bin[256];
	/*
	 * fuse-overlayfs binary used for the userspace blend fallback.
	 * When empty the daemon searches $PATH for "fuse-overlayfs".
	 */
	char fuse_overlayfs_bin[256];
	int  worker_threads;
	int  netlink_proto;
	bool daemonize;
	bool verbose;
};

/* Job types dispatched to the worker pool */
enum bdfs_job_type {
	BDFS_JOB_EXPORT_TO_DWARFS,    /* btrfs-send | mkdwarfs */
	BDFS_JOB_IMPORT_FROM_DWARFS,  /* dwarfsextract | btrfs receive */
	BDFS_JOB_MOUNT_DWARFS,        /* dwarfs */
	BDFS_JOB_UMOUNT_DWARFS,       /* fusermount -u */
	BDFS_JOB_STORE_IMAGE,         /* copy_file_range to btrfs */
	BDFS_JOB_SNAPSHOT_CONTAINER,  /* btrfs subvolume snapshot */
	BDFS_JOB_MOUNT_BLEND,         /* mount -t bdfs_blend (kernel) */
	BDFS_JOB_UMOUNT_BLEND,        /* umount blend point */
	BDFS_JOB_PROMOTE_COPYUP,      /* copy DwarFS file to BTRFS upper layer */
	/*
	 * Userspace blend mount: dwarfs FUSE + fuse-overlayfs.
	 * Used when the bdfs_blend kernel module is unavailable or when
	 * BDFS_MOUNT_USERSPACE_OVERLAY is set in the mount request.
	 */
	BDFS_JOB_MOUNT_BLEND_USERSPACE,
	/*
	 * Prune old BTRFS snapshots on a partition, keeping the N most
	 * recent by mtime.  Optionally filters by name glob pattern.
	 * Optionally demotes pruned snapshots to DwarFS before deleting.
	 */
	BDFS_JOB_PRUNE,
	/*
	 * Roll back to an autosnap snapshot:
	 *   1. Mount the top-level btrfs volume (subvolid=5).
	 *   2. Rename the current @ subvolume to @autosnap-rollback-backup-<ts>.
	 *   3. Create a new writable snapshot of the named autosnap subvolume
	 *      as the new @.
	 *   4. Unmount the top-level volume.
	 * A reboot is required for the new @ to take effect.
	 */
	BDFS_JOB_AUTOSNAP_ROLLBACK,
	BDFS_JOB_WORKSPACE_SHUTDOWN,
};

/* A unit of work dispatched to the thread pool */
struct bdfs_job {
	TAILQ_ENTRY(bdfs_job) entry;
	enum bdfs_job_type    type;
	uint8_t               partition_uuid[16];
	uint64_t              object_id; /* image_id or subvol_id */

	union {
		struct {
			char     btrfs_mount[BDFS_PATH_MAX];
			uint64_t subvol_id;
			char     image_path[BDFS_PATH_MAX];
			char     image_name[BDFS_NAME_MAX + 1];
			uint32_t compression;
			uint32_t block_size_bits;
			uint32_t worker_threads;
			uint32_t flags;
			/*
			 * Incremental export: path of the parent snapshot.
			 * Non-empty when BDFS_EXPORT_INCREMENTAL is set.
			 * Passed as -p to btrfs-send.
			 */
			char parent_snap_path[BDFS_PATH_MAX];
		} export_to_dwarfs;

		struct {
			char     image_path[BDFS_PATH_MAX];
			char     btrfs_mount[BDFS_PATH_MAX];
			char     subvol_name[BDFS_NAME_MAX + 1];
			uint32_t flags;
		} import_from_dwarfs;

		struct {
			char     image_path[BDFS_PATH_MAX];
			char     mount_point[BDFS_PATH_MAX];
			uint32_t cache_size_mb;
			uint32_t flags;
		} mount_dwarfs;

		struct {
			char     mount_point[BDFS_PATH_MAX];
			uint32_t flags;
		} umount_dwarfs;

		struct {
			char     source_path[BDFS_PATH_MAX];
			char     dest_path[BDFS_PATH_MAX];
			uint32_t flags;
		} store_image;

		struct {
			char     subvol_path[BDFS_PATH_MAX];
			char     snapshot_path[BDFS_PATH_MAX];
			uint32_t flags;
		} snapshot_container;

		struct {
			char                  btrfs_mount[BDFS_PATH_MAX];
			char                  dwarfs_mount[BDFS_PATH_MAX];
			char                  blend_mount[BDFS_PATH_MAX];
			struct bdfs_mount_opts opts;
		} mount_blend;

		/*
		 * Copy-up: promote a single file from a DwarFS lower layer
		 * to the BTRFS upper layer so it can be written.
		 * Triggered by BDFS_EVT_SNAPSHOT_CREATED with "copyup_needed".
		 */
		struct {
			uint8_t  btrfs_uuid[16]; /* blend mount's BTRFS UUID */
			uint64_t inode_no;       /* blend inode number */
			char     lower_path[BDFS_PATH_MAX]; /* source on DwarFS */
			char     upper_path[BDFS_PATH_MAX]; /* dest on BTRFS */
		} promote_copyup;

		/*
		 * Userspace blend mount via fuse-overlayfs.
		 *
		 * The daemon:
		 *   1. Mounts the DwarFS image at a private path under
		 *      state_dir using the dwarfs FUSE driver.
		 *   2. Invokes fuse-overlayfs:
		 *        fuse-overlayfs \
		 *          -o lowerdir=<dwarfs_fuse_mnt> \
		 *          -o upperdir=<btrfs_upper> \
		 *          -o workdir=<work_dir> \
		 *          <blend_mount>
		 *   3. Tracks both mounts so umount tears them down in order.
		 *
		 * The dwarfs_fuse_mnt path is constructed by the daemon as
		 * <state_dir>/.bdfs_lower_<uuid> and is not exposed to the
		 * caller; it is stored in the mount table entry so umount can
		 * find it.
		 */
		struct {
			char     dwarfs_image[BDFS_PATH_MAX]; /* .dwarfs file */
			char     btrfs_upper[BDFS_PATH_MAX];  /* BTRFS subvol */
			char     work_dir[BDFS_PATH_MAX];     /* overlayfs workdir */
			char     blend_mount[BDFS_PATH_MAX];  /* merged mountpoint */
			uint32_t cache_size_mb;
			uint32_t flags;
		} mount_blend_userspace;

		/*
		 * Prune snapshots on a BTRFS-backed partition.
		 *
		 * Lists all subvolumes under btrfs_mount, optionally filtered
		 * by name_pattern (fnmatch glob).  Sorts by mtime descending.
		 * Deletes all beyond keep_count.
		 *
		 * When demote_before_delete is set, each pruned subvolume is
		 * first exported to a DwarFS image (BDFS_JOB_EXPORT_TO_DWARFS)
		 * before deletion, archiving it at compression level
		 * demote_compression.
		 */
		struct {
			char     btrfs_mount[BDFS_PATH_MAX];
			char     name_pattern[256]; /* fnmatch glob, "" = all */
			uint32_t keep_count;        /* number of snapshots to keep */
			uint32_t flags;
#define BDFS_PRUNE_DEMOTE_FIRST (1 << 0) /* demote to DwarFS before delete */
#define BDFS_PRUNE_DRY_RUN      (1 << 1) /* log but do not delete */
			uint32_t demote_compression;
		} prune;

		struct {
			char     workspace_path[BDFS_PATH_MAX];
			uint32_t reason;
#define BDFS_WS_SHUTDOWN_PAUSE  0
#define BDFS_WS_SHUTDOWN_DELETE 1
#define BDFS_WS_SHUTDOWN_STOP   2
			uint32_t compression;
			uint32_t prune_keep;
			char     image_path[BDFS_PATH_MAX];
			char     archive_cid[256]; /* populated after IPFS pin */
		} workspace_shutdown;

		/*
		 * autosnap_rollback: roll back the root btrfs subvolume (@)
		 * to a named autosnap snapshot.
		 *
		 * btrfs_mount    - top-level btrfs mountpoint (subvolid=5)
		 * snapshot_name  - name of the autosnap-* subvolume to restore
		 *
		 * The current @ is preserved as @autosnap-rollback-backup-<ts>
		 * so the rollback itself is recoverable.
		 */
		struct {
			char btrfs_mount[BDFS_PATH_MAX];
			char snapshot_name[BDFS_NAME_MAX + 1];
		} autosnap_rollback;
	};

	/* Completion callback (called from worker thread) */
	void (*on_complete)(struct bdfs_job *job, int result);
	void *cb_data;
};

TAILQ_HEAD(bdfs_job_queue, bdfs_job);

/*
 * Active FUSE / blend mount tracking.
 *
 * The daemon records every DwarFS FUSE mount and blend mount it manages so
 * it can unmount them cleanly on shutdown and answer status queries.
 *
 * Data structures
 * ───────────────
 * bdfs_mount_entry  - one tracked mount.  Lives in two containers:
 *
 *   bdfs_mount_table (TAILQ)
 *     Ordered list used for shutdown teardown (reverse-insertion order)
 *     and for bdfs_mount_count().
 *
 *   bdfs_mount_index (open-addressing hash table, BDFS_MOUNT_HASH_SIZE slots)
 *     Keyed by mount_point string.  Gives O(1) lookup in
 *     bdfs_job_umount_blend() and bdfs_mount_untrack(), replacing the
 *     previous O(n) TAILQ_FOREACH scan.
 *
 * Both containers hold pointers to the same heap-allocated entry; the entry
 * is freed once after removal from both.
 *
 * Hash function: FNV-1a over the mount_point string, modulo table size.
 * Collision resolution: linear probing with tombstone markers.
 * Load factor is kept below 0.75 by the expected mount count (single digits).
 */
enum bdfs_mount_type {
	BDFS_MNT_DWARFS          = 1, /* DwarFS FUSE mount */
	BDFS_MNT_BLEND            = 2, /* bdfs_blend kernel overlay */
	BDFS_MNT_BLEND_USERSPACE  = 3, /* fuse-overlayfs userspace blend */
};

struct bdfs_mount_entry {
	TAILQ_ENTRY(bdfs_mount_entry) entry;   /* ordered list linkage */
	enum bdfs_mount_type          type;
	uint8_t                       partition_uuid[16];
	uint64_t                      image_id;       /* DwarFS mounts only */
	char                          mount_point[BDFS_PATH_MAX];
	/*
	 * For BDFS_MNT_BLEND_USERSPACE: the private DwarFS FUSE mountpoint
	 * that must be unmounted after the fuse-overlayfs mount is gone.
	 */
	char                          lower_fuse_mount[BDFS_PATH_MAX];
};

TAILQ_HEAD(bdfs_mount_table, bdfs_mount_entry);

/*
 * Hash index over active mounts, keyed by mount_point.
 *
 * BDFS_MOUNT_HASH_SIZE must be a power of two.  256 slots gives a load
 * factor well below 0.01 for the expected number of concurrent mounts and
 * keeps the probing sequence short even in adversarial cases.
 *
 * Slot states:
 *   NULL      - empty, never used
 *   TOMBSTONE - previously occupied, skip during probe but stop at NULL
 *   pointer   - live entry
 */
#define BDFS_MOUNT_HASH_SIZE 256u

/* Sentinel value for tombstone slots (deleted entries). */
#define BDFS_MOUNT_TOMBSTONE ((struct bdfs_mount_entry *)(uintptr_t)1)

struct bdfs_mount_index {
	struct bdfs_mount_entry *slots[BDFS_MOUNT_HASH_SIZE];
};

/* Daemon global state */
struct bdfs_daemon {
	struct bdfs_daemon_config cfg;
	int                       ctl_fd;  /* /dev/bdfs_ctl */
	int                       nl_fd;   /* netlink socket */
	int                       sock_fd; /* unix domain socket */

	/* Worker thread pool */
	pthread_t            *workers;
	int                   worker_count;
	struct bdfs_job_queue job_queue;
	pthread_mutex_t       queue_lock;
	pthread_cond_t        queue_cond;
	bool                  shutdown;

	/* Active FUSE / blend mounts tracked by the daemon */
	pthread_mutex_t         mounts_lock;
	struct bdfs_mount_table mounts; /* ordered list for shutdown teardown */
	struct bdfs_mount_index mounts_idx; /* O(1) lookup by mount_point */

	/* Auto-demote policy engine (started after init) */
	struct bdfs_policy_engine *policy;
};

/* ── Function declarations ─────────────────────────────────────────────── */

/* daemon lifecycle */
int  bdfs_daemon_init(struct bdfs_daemon *d, struct bdfs_daemon_config *cfg);
int  bdfs_daemon_run(struct bdfs_daemon *d);
void bdfs_daemon_shutdown(struct bdfs_daemon *d);

/* job dispatch */
int              bdfs_daemon_enqueue(struct bdfs_daemon *d, struct bdfs_job *job);
struct bdfs_job *bdfs_job_alloc(enum bdfs_job_type type);
void             bdfs_job_free(struct bdfs_job *job);

/* job handlers (implemented in bdfs_jobs.c) */
int bdfs_job_export_to_dwarfs(struct bdfs_daemon *d, struct bdfs_job *job);
int bdfs_job_import_from_dwarfs(struct bdfs_daemon *d, struct bdfs_job *job);
int bdfs_job_mount_dwarfs(struct bdfs_daemon *d, struct bdfs_job *job);
int bdfs_job_umount_dwarfs(struct bdfs_daemon *d, struct bdfs_job *job);
int bdfs_job_store_image(struct bdfs_daemon *d, struct bdfs_job *job);
int bdfs_job_snapshot_container(struct bdfs_daemon *d, struct bdfs_job *job);
int bdfs_job_mount_blend(struct bdfs_daemon *d, struct bdfs_job *job);
int bdfs_job_umount_blend(struct bdfs_daemon *d, struct bdfs_job *job);
int bdfs_job_promote_copyup(struct bdfs_daemon *d, struct bdfs_job *job);
int bdfs_job_mount_blend_userspace(struct bdfs_daemon *d, struct bdfs_job *job);
int bdfs_job_prune(struct bdfs_daemon *d, struct bdfs_job *job);
int bdfs_job_autosnap_rollback(struct bdfs_daemon *d, struct bdfs_job *job);
int bdfs_job_workspace_shutdown(struct bdfs_daemon *d, struct bdfs_job *job);
int bdfs_exec_wait_timeout(const char *const argv[], int timeout_s);
/*
 * bdfs_exec_capture_output - fork+exec argv[], capture stdout into buf.
 *
 * Like bdfs_exec_wait_timeout but stdout is piped back to the caller.
 * At most bufsz-1 bytes are stored; buf is always NUL-terminated.
 * Returns 0 on success, -ETIMEDOUT on timeout, -errno / -EIO on error.
 */
int bdfs_exec_capture_output(const char *const argv[], int timeout_s,
			     char *buf, size_t bufsz);

/* mount table helpers */
void bdfs_mount_track(struct bdfs_daemon *d, enum bdfs_mount_type type,
		      const uint8_t uuid[16], uint64_t image_id,
		      const char *mount_point);
void bdfs_mount_track_userspace_blend(struct bdfs_daemon *d,
				      const uint8_t uuid[16],
				      const char *blend_mount,
				      const char *lower_fuse_mount);
void bdfs_mount_untrack(struct bdfs_daemon *d, const char *mount_point);
int  bdfs_mount_count(struct bdfs_daemon *d);

/*
 * bdfs_mount_lookup - O(1) lookup of a mount entry by mount_point.
 *
 * Returns the entry pointer, or NULL if not found.
 * Must be called with d->mounts_lock held.
 */
struct bdfs_mount_entry *bdfs_mount_lookup(struct bdfs_daemon *d,
					   const char *mount_point);

/* netlink event listener (bdfs_netlink.c) */
#ifndef bdfs_netlink_init
int bdfs_netlink_init(struct bdfs_daemon *d);
#endif
void bdfs_netlink_loop(struct bdfs_daemon *d);

/* unix socket server for CLI (bdfs_socket.c) */
#ifndef bdfs_socket_init
int bdfs_socket_init(struct bdfs_daemon *d);
#endif
void bdfs_socket_loop(struct bdfs_daemon *d);

/* tool execution helpers (bdfs_exec.c) */
int bdfs_exec_wait(const char *const argv[]);
int bdfs_exec_mkdwarfs(struct bdfs_daemon *d, const char *input_dir,
		       const char *output_image, uint32_t compression,
		       uint32_t block_size_bits, int worker_threads);
int bdfs_exec_dwarfsextract(struct bdfs_daemon *d, const char *image_path,
			    const char *output_dir);
int bdfs_exec_dwarfs_mount(struct bdfs_daemon *d, const char *image_path,
			   const char *mount_point, uint32_t cache_mb);
int bdfs_exec_dwarfs_umount(struct bdfs_daemon *d, const char *mount_point);
int bdfs_exec_fuse_overlayfs(struct bdfs_daemon *d, const char *lower,
			     const char *upper, const char *work,
			     const char *merged);
int bdfs_exec_btrfs_send(struct bdfs_daemon *d, const char *subvol_path,
			 int *pipe_read_fd_out);
int bdfs_exec_btrfs_send_incremental(struct bdfs_daemon *d,
				     const char *subvol_path,
				     const char *parent_snap_path,
				     int *pipe_read_fd_out);
int bdfs_exec_btrfs_receive(struct bdfs_daemon *d, const char *dest_dir,
			    int pipe_write_fd);
int bdfs_exec_btrfs_snapshot(struct bdfs_daemon *d, const char *source_subvol,
			     const char *dest_path, bool readonly);
int bdfs_exec_btrfs_subvol_create(struct bdfs_daemon *d, const char *path);
int bdfs_exec_btrfs_subvol_delete(struct bdfs_daemon *d, const char *path);

#endif /* _BDFS_DAEMON_H */
