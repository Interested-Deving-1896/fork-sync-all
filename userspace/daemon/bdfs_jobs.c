// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * bdfs_jobs.c - Job handler implementations
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <fnmatch.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <syslog.h>
#include <unistd.h>

#include "bdfs_daemon.h"

/* ── Export: BTRFS subvolume → DwarFS image ─────────────────────────────── */
int bdfs_job_export_to_dwarfs(struct bdfs_daemon *d, struct bdfs_job *job)
{
	const struct bdfs_job *j = job;
	char snap_path[BDFS_PATH_MAX];
	char extract_dir[BDFS_PATH_MAX];
	char tmp_image[BDFS_PATH_MAX];
	int  ret;

	snprintf(snap_path, sizeof(snap_path),
		 "%s/.bdfs_snap_%" PRIu64,
		 j->export_to_dwarfs.btrfs_mount,
		 j->export_to_dwarfs.subvol_id);

	ret = bdfs_exec_btrfs_snapshot(d,
		j->export_to_dwarfs.btrfs_mount,
		snap_path, true);
	if (ret) {
		syslog(LOG_ERR, "bdfs: export: snapshot failed: %d", ret);
		return ret;
	}

	snprintf(extract_dir, sizeof(extract_dir),
		 "%s/.bdfs_extract_%" PRIu64,
		 d->cfg.state_dir,
		 j->export_to_dwarfs.subvol_id);

	if (mkdir(extract_dir, 0700) < 0 && errno != EEXIST) {
		syslog(LOG_ERR, "bdfs: export: mkdir %s: %m", extract_dir);
		bdfs_exec_btrfs_subvol_delete(d, snap_path);
		return -errno;
	}

	{
		int   pipe_fd;
		pid_t send_pid;
		const char *parent = NULL;
		int   send_status;

		if ((j->export_to_dwarfs.flags & BDFS_EXPORT_INCREMENTAL) &&
		    j->export_to_dwarfs.parent_snap_path[0])
			parent = j->export_to_dwarfs.parent_snap_path;

		send_pid = bdfs_exec_btrfs_send_incremental(d, snap_path,
							    parent, &pipe_fd);
		if (send_pid < 0) {
			syslog(LOG_ERR, "bdfs: export: btrfs send failed: %d",
			       send_pid);
			bdfs_exec_btrfs_subvol_delete(d, snap_path);
			return send_pid;
		}

		ret = bdfs_exec_btrfs_receive(d, extract_dir, pipe_fd);
		close(pipe_fd);

		if (waitpid(send_pid, &send_status, 0) < 0)
			syslog(LOG_WARNING,
			       "bdfs: export: waitpid send: %m");
		else if (!WIFEXITED(send_status) || WEXITSTATUS(send_status))
			syslog(LOG_WARNING,
			       "bdfs: export: btrfs send exited with status %d",
			       WIFEXITED(send_status)
				       ? WEXITSTATUS(send_status) : -1);

		if (ret) {
			syslog(LOG_ERR,
			       "bdfs: export: btrfs receive failed: %d", ret);
			bdfs_exec_btrfs_subvol_delete(d, snap_path);
			return ret;
		}
	}

	snprintf(tmp_image, sizeof(tmp_image),
		 "%s/%s.dwarfs.tmp",
		 d->cfg.state_dir,
		 j->export_to_dwarfs.image_name);

	ret = bdfs_exec_mkdwarfs(d, extract_dir, tmp_image,
				 j->export_to_dwarfs.compression,
				 j->export_to_dwarfs.block_size_bits,
				 (int)j->export_to_dwarfs.worker_threads);
	if (ret) {
		syslog(LOG_ERR, "bdfs: export: mkdwarfs failed: %d", ret);
		goto cleanup;
	}

	if (rename(tmp_image, j->export_to_dwarfs.image_path) < 0) {
		syslog(LOG_ERR, "bdfs: export: rename %s → %s: %m",
		       tmp_image, j->export_to_dwarfs.image_path);
		ret = -errno;
		goto cleanup;
	}

	syslog(LOG_INFO, "bdfs: export complete: subvol %" PRIu64 " → %s",
	       j->export_to_dwarfs.subvol_id,
	       j->export_to_dwarfs.image_path);

	if (j->export_to_dwarfs.flags & BDFS_DEMOTE_DELETE_SUBVOL) {
		int del_ret = bdfs_exec_btrfs_subvol_delete(
			d, j->export_to_dwarfs.btrfs_mount);
		if (del_ret)
			syslog(LOG_WARNING,
			       "bdfs: export: delete subvol %s failed: %d "
			       "(image written successfully)",
			       j->export_to_dwarfs.btrfs_mount, del_ret);
		else
			syslog(LOG_INFO,
			       "bdfs: export: deleted source subvol %s",
			       j->export_to_dwarfs.btrfs_mount);
	}

	ret = 0;

cleanup:
	bdfs_exec_btrfs_subvol_delete(d, snap_path);
	{
		char rm_cmd[BDFS_PATH_MAX + 8];
		snprintf(rm_cmd, sizeof(rm_cmd), "rm -rf %s", extract_dir);
		system(rm_cmd);
	}
	if (ret && access(tmp_image, F_OK) == 0)
		unlink(tmp_image);
	return ret;
}

/* ── Import: DwarFS image → BTRFS subvolume ─────────────────────────────── */
int bdfs_job_import_from_dwarfs(struct bdfs_daemon *d, struct bdfs_job *job)
{
	const struct bdfs_job *j = job;
	char subvol_path[BDFS_PATH_MAX];
	int  ret;

	snprintf(subvol_path, sizeof(subvol_path), "%s/%s",
		 j->import_from_dwarfs.btrfs_mount,
		 j->import_from_dwarfs.subvol_name);

	ret = bdfs_exec_btrfs_subvol_create(d, subvol_path);
	if (ret) {
		syslog(LOG_ERR, "bdfs: import: subvol create %s failed: %d",
		       subvol_path, ret);
		return ret;
	}

	ret = bdfs_exec_dwarfsextract(d,
		j->import_from_dwarfs.image_path, subvol_path);
	if (ret) {
		syslog(LOG_ERR, "bdfs: import: dwarfsextract failed: %d", ret);
		bdfs_exec_btrfs_subvol_delete(d, subvol_path);
		return ret;
	}

	if (j->import_from_dwarfs.flags & BDFS_IMPORT_READONLY) {
		const char *argv[] = {
			d->cfg.btrfs_bin, "property", "set", "-ts",
			subvol_path, "ro", "true", NULL
		};
		ret = bdfs_exec_wait(argv);
		if (ret)
			syslog(LOG_WARNING,
			       "bdfs: import: failed to set subvol ro on %s: %d"
			       " (subvol created but not read-only)",
			       subvol_path, ret);
		else
			syslog(LOG_INFO,
			       "bdfs: import: subvol %s set read-only",
			       subvol_path);
		ret = 0;
	}

	syslog(LOG_INFO, "bdfs: import complete: %s → subvol %s",
	       j->import_from_dwarfs.image_path, subvol_path);
	return 0;
}

/* ── Mount DwarFS image ─────────────────────────────────────────────────── */
int bdfs_job_mount_dwarfs(struct bdfs_daemon *d, struct bdfs_job *job)
{
	const struct bdfs_job *j = job;
	int ret;

	if (mkdir(j->mount_dwarfs.mount_point, 0755) < 0 && errno != EEXIST) {
		syslog(LOG_ERR, "bdfs: mount: mkdir %s: %m",
		       j->mount_dwarfs.mount_point);
		return -errno;
	}

	ret = bdfs_exec_dwarfs_mount(d,
		j->mount_dwarfs.image_path,
		j->mount_dwarfs.mount_point,
		j->mount_dwarfs.cache_size_mb);
	if (ret == 0) {
		syslog(LOG_INFO, "bdfs: mounted %s at %s",
		       j->mount_dwarfs.image_path,
		       j->mount_dwarfs.mount_point);
		bdfs_mount_track(d, BDFS_MNT_DWARFS,
				 j->partition_uuid, j->object_id,
				 j->mount_dwarfs.mount_point);
	}
	return ret;
}

/* ── Unmount DwarFS image ───────────────────────────────────────────────── */
int bdfs_job_umount_dwarfs(struct bdfs_daemon *d, struct bdfs_job *job)
{
	int ret = bdfs_exec_dwarfs_umount(d, job->umount_dwarfs.mount_point);
	if (ret == 0)
		bdfs_mount_untrack(d, job->umount_dwarfs.mount_point);
	return ret;
}

/* ── Store DwarFS image onto BTRFS partition ────────────────────────────── */
int bdfs_job_store_image(struct bdfs_daemon *d, struct bdfs_job *job)
{
	const struct bdfs_job *j = job;
	int     src_fd = -1, dst_fd = -1;
	struct  stat st;
	off_t   offset = 0;
	ssize_t copied;
	int     ret = 0;

	(void)d;

	src_fd = open(j->store_image.source_path, O_RDONLY | O_CLOEXEC);
	if (src_fd < 0) {
		syslog(LOG_ERR, "bdfs: store: open %s: %m",
		       j->store_image.source_path);
		return -errno;
	}

	if (fstat(src_fd, &st) < 0) {
		ret = -errno;
		goto out;
	}

	dst_fd = open(j->store_image.dest_path,
		      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644);
	if (dst_fd < 0) {
		syslog(LOG_ERR, "bdfs: store: create %s: %m",
		       j->store_image.dest_path);
		ret = -errno;
		goto out;
	}

	while (offset < st.st_size) {
		copied = copy_file_range(src_fd, &offset, dst_fd, NULL,
					 (size_t)(st.st_size - offset), 0);
		if (copied < 0) {
			if (errno == EXDEV || errno == EOPNOTSUPP) {
				off_t sf_off = offset;
				copied = sendfile(dst_fd, src_fd, &sf_off,
						  (size_t)(st.st_size - offset));
				if (copied < 0) {
					ret = -errno;
					goto out;
				}
				offset = sf_off;
			} else {
				ret = -errno;
				goto out;
			}
		}
	}

	syslog(LOG_INFO, "bdfs: stored %s → %s (%lld bytes)",
	       j->store_image.source_path, j->store_image.dest_path,
	       (long long)st.st_size);
out:
	if (src_fd >= 0) close(src_fd);
	if (dst_fd >= 0) {
		close(dst_fd);
		if (ret) unlink(j->store_image.dest_path);
	}
	return ret;
}

/* ── Snapshot BTRFS subvolume containing a DwarFS image ─────────────────── */
int bdfs_job_snapshot_container(struct bdfs_daemon *d, struct bdfs_job *job)
{
	const struct bdfs_job *j = job;
	bool readonly = !!(j->snapshot_container.flags & BDFS_SNAP_READONLY);
	return bdfs_exec_btrfs_snapshot(d,
		j->snapshot_container.subvol_path,
		j->snapshot_container.snapshot_path,
		readonly);
}

/* ── Mount blend layer (kernel module) ──────────────────────────────────── */
int bdfs_job_mount_blend(struct bdfs_daemon *d, struct bdfs_job *job)
{
	const struct bdfs_job *j = job;
	char opts[512];
	int  ret;

	(void)d;

	if (mkdir(j->mount_blend.blend_mount, 0755) < 0 && errno != EEXIST) {
		syslog(LOG_ERR, "bdfs: blend mount: mkdir %s: %m",
		       j->mount_blend.blend_mount);
		return -errno;
	}

	snprintf(opts, sizeof(opts), "btrfs=%s,dwarfs=%s",
		 j->mount_blend.btrfs_mount,
		 j->mount_blend.dwarfs_mount);

	ret = mount("none", j->mount_blend.blend_mount, "bdfs_blend", 0, opts);
	if (ret < 0) {
		syslog(LOG_ERR, "bdfs: blend mount %s failed: %m",
		       j->mount_blend.blend_mount);
		return -errno;
	}

	syslog(LOG_INFO, "bdfs: blend mounted at %s",
	       j->mount_blend.blend_mount);
	bdfs_mount_track(d, BDFS_MNT_BLEND, j->partition_uuid, 0,
			 j->mount_blend.blend_mount);
	return 0;
}

/* ── Unmount blend layer ────────────────────────────────────────────────── */
int bdfs_job_umount_blend(struct bdfs_daemon *d, struct bdfs_job *job)
{
	const struct bdfs_job *j = job;
	const char *mnt = j->mount_blend.blend_mount;

	/*
	 * O(1) lookup via the hash index to determine whether this is a
	 * kernel blend mount or a userspace fuse-overlayfs blend mount.
	 * The umount sequence differs: for the userspace variant we must
	 * also tear down the private DwarFS FUSE mount underneath it.
	 */
	pthread_mutex_lock(&d->mounts_lock);
	struct bdfs_mount_entry *entry = bdfs_mount_lookup(d, mnt);
	pthread_mutex_unlock(&d->mounts_lock);

	bool is_userspace = (entry &&
			     entry->type == BDFS_MNT_BLEND_USERSPACE);
	char lower_fuse[BDFS_PATH_MAX] = "";
	if (is_userspace && entry->lower_fuse_mount[0])
		snprintf(lower_fuse, sizeof(lower_fuse), "%s",
			 entry->lower_fuse_mount);

	/* Unmount the top-level overlay (kernel or fuse-overlayfs) */
	int ret;
	if (is_userspace) {
		/* fuse-overlayfs is a FUSE mount — use fusermount */
		ret = bdfs_exec_dwarfs_umount(d, mnt);
	} else {
		ret = umount2(mnt, MNT_DETACH);
		if (ret < 0) {
			syslog(LOG_ERR, "bdfs: blend umount %s: %m", mnt);
			return -errno;
		}
	}

	if (ret == 0)
		bdfs_mount_untrack(d, mnt);

	/* For userspace blends, also unmount the private DwarFS lower layer */
	if (is_userspace && lower_fuse[0]) {
		int lret = bdfs_exec_dwarfs_umount(d, lower_fuse);
		if (lret)
			syslog(LOG_WARNING,
			       "bdfs: blend umount: failed to unmount "
			       "lower DwarFS FUSE mount %s: %d",
			       lower_fuse, lret);
		else
			syslog(LOG_INFO,
			       "bdfs: blend umount: lower DwarFS mount %s "
			       "unmounted", lower_fuse);
	}

	syslog(LOG_INFO, "bdfs: blend unmounted: %s", mnt);
	return ret;
}

/* ── Copy-up: promote DwarFS file to BTRFS upper layer ──────────────────── */
int bdfs_job_promote_copyup(struct bdfs_daemon *d, struct bdfs_job *job)
{
	const struct bdfs_job *j = job;
	const char *src = j->promote_copyup.lower_path;
	const char *dst = j->promote_copyup.upper_path;
	struct stat st;
	int src_fd = -1, dst_fd = -1;
	off_t   offset = 0;
	ssize_t copied;
	int     ret = 0;
	char    parent[BDFS_PATH_MAX];
	char   *slash;

	snprintf(parent, sizeof(parent), "%s", dst);
	slash = strrchr(parent, '/');
	if (slash && slash != parent) {
		*slash = '\0';
		for (char *p = parent + 1; *p; p++) {
			if (*p != '/') continue;
			*p = '\0';
			if (mkdir(parent, 0755) < 0 && errno != EEXIST) {
				syslog(LOG_ERR,
				       "bdfs: copyup: mkdir %s: %m", parent);
				return -errno;
			}
			*p = '/';
		}
		if (mkdir(parent, 0755) < 0 && errno != EEXIST) {
			syslog(LOG_ERR, "bdfs: copyup: mkdir %s: %m", parent);
			return -errno;
		}
	}

	src_fd = open(src, O_RDONLY | O_CLOEXEC);
	if (src_fd < 0) {
		syslog(LOG_ERR, "bdfs: copyup: open src %s: %m", src);
		return -errno;
	}
	if (fstat(src_fd, &st) < 0) { ret = -errno; goto out; }

	dst_fd = open(dst, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
		      st.st_mode & 0777);
	if (dst_fd < 0 && errno == EEXIST) { ret = 0; goto out; }
	if (dst_fd < 0) {
		syslog(LOG_ERR, "bdfs: copyup: create dst %s: %m", dst);
		ret = -errno;
		goto out;
	}

	while (offset < st.st_size) {
		copied = copy_file_range(src_fd, &offset, dst_fd, NULL,
					 (size_t)(st.st_size - offset), 0);
		if (copied < 0) {
			if (errno == EXDEV || errno == EOPNOTSUPP) {
				char buf[65536];
				ssize_t n;
				while ((n = read(src_fd, buf, sizeof(buf))) > 0)
					if (write(dst_fd, buf, (size_t)n) != n) {
						ret = -errno; break;
					}
				if (n < 0) ret = -errno;
				break;
			}
			ret = -errno;
			goto out;
		}
	}

	if (fchown(dst_fd, st.st_uid, st.st_gid) < 0)
		syslog(LOG_WARNING, "bdfs: copyup: chown %s: %m", dst);
	{
		struct timespec times[2] = { st.st_atim, st.st_mtim };
		if (futimens(dst_fd, times) < 0)
			syslog(LOG_WARNING, "bdfs: copyup: utimens %s: %m", dst);
	}
	syslog(LOG_INFO, "bdfs: copyup complete: %s → %s", src, dst);

out:
	if (src_fd >= 0) close(src_fd);
	if (dst_fd >= 0) {
		close(dst_fd);
		if (ret) unlink(dst);
	}
	if (ret == 0) {
		struct bdfs_ioctl_copyup_complete arg;
		memset(&arg, 0, sizeof(arg));
		memcpy(arg.btrfs_uuid, j->promote_copyup.btrfs_uuid, 16);
		arg.inode_no = j->promote_copyup.inode_no;
		snprintf(arg.upper_path, sizeof(arg.upper_path), "%s", dst);
		if (ioctl(d->ctl_fd, BDFS_IOC_COPYUP_COMPLETE, &arg) < 0)
			syslog(LOG_ERR,
			       "bdfs: copyup: BDFS_IOC_COPYUP_COMPLETE "
			       "failed: %m");
	}
	return ret;
}

/* ── Prune old BTRFS snapshots ──────────────────────────────────────────── */

/*
 * Snapshot entry for sorting by mtime.
 */
struct snap_entry {
	char    path[BDFS_PATH_MAX];
	time_t  mtime;
};

static int snap_mtime_desc(const void *a, const void *b)
{
	const struct snap_entry *sa = a, *sb = b;
	if (sb->mtime > sa->mtime) return  1;
	if (sb->mtime < sa->mtime) return -1;
	return 0;
}

/*
 * bdfs_job_prune - Delete old BTRFS snapshots beyond keep_count.
 *
 * 1. Enumerate subvolumes under btrfs_mount via `btrfs subvolume list`.
 * 2. Filter by name_pattern (fnmatch) if set.
 * 3. Sort by mtime descending (newest first).
 * 4. Keep the first keep_count; process the rest:
 *    a. If BDFS_PRUNE_DEMOTE_FIRST: enqueue BDFS_JOB_EXPORT_TO_DWARFS.
 *    b. Unless BDFS_PRUNE_DRY_RUN: delete the subvolume.
 */
int bdfs_job_prune(struct bdfs_daemon *d, struct bdfs_job *job)
{
	const struct bdfs_job *j = job;
	const char *mount = j->prune.btrfs_mount;
	const char *pat   = j->prune.name_pattern;
	uint32_t    keep  = j->prune.keep_count;
	bool        dry   = !!(j->prune.flags & BDFS_PRUNE_DRY_RUN);
	bool        demote = !!(j->prune.flags & BDFS_PRUNE_DEMOTE_FIRST);

	/* Run `btrfs subvolume list -o <mount>` and parse output */
	char cmd[BDFS_PATH_MAX + 64];
	snprintf(cmd, sizeof(cmd),
		 "%s subvolume list -o %s 2>/dev/null",
		 d->cfg.btrfs_bin, mount);

	FILE *fp = popen(cmd, "r");
	if (!fp) {
		syslog(LOG_ERR, "bdfs: prune: popen btrfs list: %m");
		return -errno;
	}

	struct snap_entry *snaps = NULL;
	size_t count = 0, cap = 0;
	char line[BDFS_PATH_MAX + 128];

	while (fgets(line, sizeof(line), fp)) {
		/* Format: "ID <n> gen <n> top level <n> path <name>" */
		char name[BDFS_PATH_MAX] = "";
		if (sscanf(line, "%*s %*u %*s %*u %*s %*u %*s %s", name) != 1)
			continue;

		/* Apply name pattern filter */
		if (pat[0] && fnmatch(pat, name, 0) != 0)
			continue;

		char full_path[BDFS_PATH_MAX];
		snprintf(full_path, sizeof(full_path), "%s/%s", mount, name);

		struct stat st;
		if (stat(full_path, &st) < 0)
			continue;

		if (count >= cap) {
			cap = cap ? cap * 2 : 64;
			struct snap_entry *tmp = realloc(snaps,
						cap * sizeof(*snaps));
			if (!tmp) {
				syslog(LOG_ERR, "bdfs: prune: out of memory");
				pclose(fp);
				free(snaps);
				return -ENOMEM;
			}
			snaps = tmp;
		}

		strncpy(snaps[count].path, full_path, BDFS_PATH_MAX - 1);
		snaps[count].mtime = st.st_mtime;
		count++;
	}
	pclose(fp);

	if (count == 0) {
		syslog(LOG_INFO, "bdfs: prune: no snapshots found under %s "
		       "(pattern='%s')", mount, pat[0] ? pat : "*");
		free(snaps);
		return 0;
	}

	/* Sort newest-first */
	qsort(snaps, count, sizeof(*snaps), snap_mtime_desc);

	syslog(LOG_INFO,
	       "bdfs: prune: found %zu snapshot(s) under %s, keeping %u",
	       count, mount, keep);

	int ret = 0;
	for (size_t i = keep; i < count; i++) {
		const char *path = snaps[i].path;

		if (dry) {
			syslog(LOG_INFO,
			       "bdfs: prune: [dry-run] would delete %s", path);
			continue;
		}

		/* Optionally demote to DwarFS before deleting */
		if (demote) {
			struct bdfs_job *djob =
				bdfs_job_alloc(BDFS_JOB_EXPORT_TO_DWARFS);
			if (djob) {
				memcpy(djob->partition_uuid,
				       j->partition_uuid, 16);
				strncpy(djob->export_to_dwarfs.btrfs_mount,
					path, BDFS_PATH_MAX - 1);
				djob->export_to_dwarfs.compression =
					j->prune.demote_compression
					? j->prune.demote_compression
					: BDFS_COMPRESS_ZSTD;
				djob->export_to_dwarfs.worker_threads = 2;
				djob->export_to_dwarfs.flags =
					BDFS_DEMOTE_DELETE_SUBVOL;

				const char *base = strrchr(path, '/');
				base = base ? base + 1 : path;
				strncpy(djob->export_to_dwarfs.image_name,
					base, BDFS_NAME_MAX);

				bdfs_daemon_enqueue(d, djob);
				syslog(LOG_INFO,
				       "bdfs: prune: queued demote for %s",
				       path);
				/* Deletion handled by the demote job */
				continue;
			}
		}

		/* Direct delete */
		int del = bdfs_exec_btrfs_subvol_delete(d, path);
		if (del) {
			syslog(LOG_ERR,
			       "bdfs: prune: delete %s failed: %d", path, del);
			ret = del;
		} else {
			syslog(LOG_INFO, "bdfs: prune: deleted %s", path);
		}
	}

	free(snaps);
	return ret;
}

/* ── Autosnap rollback ───────────────────────────────────────────────────── */

/*
 * resolve_btrfs_device - Resolve the block device path for a mountpoint by
 * parsing /proc/self/mountinfo directly.
 *
 * This avoids popen()/findmnt which are vulnerable to shell injection if the
 * mountpoint path contains special characters, and whose failure modes are
 * difficult to handle cleanly in a daemon context.
 *
 * /proc/self/mountinfo format (field indices, space-separated):
 *   0:mount_id 1:parent_id 2:major:minor 3:root 4:mount_point 5:mount_opts
 *   [optional tagged fields...] - 7:fs_type 8:source 9:super_opts
 *
 * We match on field 4 (mount_point) and return field 8 (source device).
 * Returns 0 on success, -ENODEV if not found, -EIO on parse error.
 */
static int resolve_btrfs_device(const char *mountpoint,
				char *dev_out, size_t dev_out_len)
{
	FILE  *fp;
	char   line[4096];
	int    found = 0;

	fp = fopen("/proc/self/mountinfo", "r");
	if (!fp) {
		syslog(LOG_ERR,
		       "bdfs: resolve_btrfs_device: open /proc/self/mountinfo: %m");
		return -EIO;
	}

	while (fgets(line, sizeof(line), fp)) {
		/*
		 * Parse the fixed fields up to the separator " - ".
		 * We need field index 4 (mount_point).
		 * After the " - " separator: fs_type source super_opts.
		 */
		char *sep = strstr(line, " - ");
		if (!sep)
			continue;

		/* Isolate the pre-separator portion and tokenise */
		*sep = '\0';
		char *post = sep + 3; /* points to "fs_type source ..." */

		char *fields[6] = {0};
		char *tok = strtok(line, " ");
		int   fi  = 0;
		while (tok && fi < 6) {
			fields[fi++] = tok;
			tok = strtok(NULL, " ");
		}
		/* field[4] is mount_point */
		if (fi < 5 || !fields[4])
			continue;
		if (strcmp(fields[4], mountpoint) != 0)
			continue;

		/* Parse post-separator: fs_type source super_opts */
		char fs_type[64]  = "";
		char source[BDFS_PATH_MAX] = "";
		if (sscanf(post, "%63s %*s", fs_type) < 1)
			continue;
		/* Skip fs_type token to get source */
		char *src_start = strchr(post, ' ');
		if (!src_start)
			continue;
		src_start++;
		if (sscanf(src_start, "%*s") < 0) { /* advance past fs_type */ }
		/* Re-parse: fs_type<sp>source */
		if (sscanf(post, "%63s %4095s", fs_type, source) < 2)
			continue;

		if (strcmp(fs_type, "btrfs") != 0) {
			syslog(LOG_ERR,
			       "bdfs: resolve_btrfs_device: %s is %s, not btrfs",
			       mountpoint, fs_type);
			fclose(fp);
			return -EINVAL;
		}

		strncpy(dev_out, source, dev_out_len - 1);
		dev_out[dev_out_len - 1] = '\0';
		found = 1;
		break;
	}

	fclose(fp);
	return found ? 0 : -ENODEV;
}

/*
 * bdfs_job_autosnap_rollback - Roll back the root btrfs subvolume (@) to a
 * named autosnap snapshot.
 *
 * Crash-safe ordering — the live @ is never removed until its replacement
 * is confirmed to exist on disk:
 *
 *   1. Resolve the block device via /proc/self/mountinfo (no shell injection).
 *   2. Mount the top-level btrfs volume (subvolid=5) at a private tmpdir.
 *   3. Verify the named autosnap-* subvolume exists.
 *   4. Create the replacement as @autosnap-new-<timestamp> (snapshot of the
 *      autosnap subvolume). The live @ is untouched at this point.
 *   5. Verify the new subvolume was created successfully (stat check).
 *   6. Rename @ → @autosnap-rollback-backup-<timestamp>.
 *   7. Rename @autosnap-new-<timestamp> → @.
 *   8. Unmount and clean up.
 *
 * Failure modes:
 *   - Steps 1–5 fail  → no changes to @ whatsoever; clean abort.
 *   - Step 6 fails    → new subvolume exists but is unused; delete it and
 *                        return error. @ is intact.
 *   - Step 7 fails    → backup exists, new subvolume exists, @ is intact.
 *                        Rename the backup back, delete the new subvolume,
 *                        return error. Fully recoverable.
 *   - Unmount fails   → logged at WARNING; kernel will clean up on reboot.
 *
 * The caller must reboot for the new @ to take effect.
 */
int bdfs_job_autosnap_rollback(struct bdfs_daemon *d, struct bdfs_job *job)
{
	const char *btrfs_mount = job->autosnap_rollback.btrfs_mount;
	const char *snap_name   = job->autosnap_rollback.snapshot_name;

	char   tmpdir[BDFS_PATH_MAX];
	char   dev[BDFS_PATH_MAX];
	char   snap_path[BDFS_PATH_MAX];
	char   current_at[BDFS_PATH_MAX];
	char   backup_at[BDFS_PATH_MAX];
	char   new_staging[BDFS_PATH_MAX]; /* @autosnap-new-<ts> */
	char   final_at[BDFS_PATH_MAX];
	time_t now;
	struct tm tm_now;
	char   ts[32];
	int    ret = 0;

	/* Validate snapshot name prefix */
	if (strncmp(snap_name, "autosnap-", 9) != 0) {
		syslog(LOG_ERR,
		       "bdfs: autosnap_rollback: '%s' is not an autosnap snapshot",
		       snap_name);
		return -EINVAL;
	}

	/* Build timestamp string used for both staging and backup names */
	time(&now);
	gmtime_r(&now, &tm_now);
	strftime(ts, sizeof(ts), "%Y-%m-%dT%H:%M:%SZ", &tm_now);

	/* Step 1: resolve block device from /proc/self/mountinfo */
	ret = resolve_btrfs_device(btrfs_mount, dev, sizeof(dev));
	if (ret) {
		syslog(LOG_ERR,
		       "bdfs: autosnap_rollback: cannot resolve device for %s: %d",
		       btrfs_mount, ret);
		return ret;
	}

	/* Step 2: mount top-level btrfs volume (subvolid=5) */
	snprintf(tmpdir, sizeof(tmpdir),
		 "%s/.bdfs_rollback_XXXXXX", d->cfg.state_dir);
	if (!mkdtemp(tmpdir)) {
		syslog(LOG_ERR, "bdfs: autosnap_rollback: mkdtemp: %m");
		return -errno;
	}

	if (mount(dev, tmpdir, "btrfs", 0, "subvolid=5") < 0) {
		syslog(LOG_ERR,
		       "bdfs: autosnap_rollback: mount %s (subvolid=5) at %s: %m",
		       dev, tmpdir);
		rmdir(tmpdir);
		return -errno;
	}

	/* Build all paths now that tmpdir is known */
	snprintf(snap_path,   sizeof(snap_path),   "%s/%s",                       tmpdir, snap_name);
	snprintf(current_at,  sizeof(current_at),  "%s/@",                        tmpdir);
	snprintf(new_staging, sizeof(new_staging), "%s/@autosnap-new-%s",         tmpdir, ts);
	snprintf(backup_at,   sizeof(backup_at),   "%s/@autosnap-rollback-backup-%s", tmpdir, ts);
	snprintf(final_at,    sizeof(final_at),    "%s/@",                        tmpdir);

	/* Step 3: verify the source snapshot exists */
	{
		struct stat st;
		if (stat(snap_path, &st) < 0) {
			syslog(LOG_ERR,
			       "bdfs: autosnap_rollback: snapshot not found: %s",
			       snap_path);
			ret = -ENOENT;
			goto out_umount;
		}
	}

	/*
	 * Step 4: create the replacement subvolume as @autosnap-new-<ts>.
	 * The live @ is completely untouched at this point.
	 */
	ret = bdfs_exec_btrfs_snapshot(d, snap_path, new_staging,
				       false /* writable */);
	if (ret) {
		syslog(LOG_ERR,
		       "bdfs: autosnap_rollback: create staging snapshot "
		       "%s → %s failed: %d",
		       snap_name, new_staging, ret);
		goto out_umount;
	}

	/* Step 5: verify the staging subvolume actually exists on disk */
	{
		struct stat st;
		if (stat(new_staging, &st) < 0) {
			syslog(LOG_ERR,
			       "bdfs: autosnap_rollback: staging subvolume "
			       "missing after creation: %s: %m",
			       new_staging);
			ret = -EIO;
			/* Clean up the (apparently incomplete) staging subvol */
			bdfs_exec_btrfs_subvol_delete(d, new_staging);
			goto out_umount;
		}
	}

	/*
	 * Step 6: rename @ → @autosnap-rollback-backup-<ts>.
	 * First point of no return — but the staging subvolume already exists,
	 * so recovery is deterministic if step 7 fails.
	 */
	if (rename(current_at, backup_at) < 0) {
		syslog(LOG_ERR,
		       "bdfs: autosnap_rollback: rename @ → backup: %m");
		ret = -errno;
		/* @ is intact; clean up the unused staging subvolume */
		bdfs_exec_btrfs_subvol_delete(d, new_staging);
		goto out_umount;
	}

	syslog(LOG_INFO,
	       "bdfs: autosnap_rollback: @ saved as @autosnap-rollback-backup-%s",
	       ts);

	/*
	 * Step 7: rename @autosnap-new-<ts> → @.
	 * If this fails: backup exists, staging exists, @ is gone.
	 * Recover by renaming backup back to @ and deleting staging.
	 */
	if (rename(new_staging, final_at) < 0) {
		syslog(LOG_ERR,
		       "bdfs: autosnap_rollback: rename staging → @: %m");
		ret = -errno;

		if (rename(backup_at, current_at) < 0) {
			/*
			 * Both renames failed. The system has no @ subvolume.
			 * Log at EMERG — operator intervention required before
			 * reboot. The backup and staging subvolumes are intact.
			 */
			syslog(LOG_EMERG,
			       "bdfs: autosnap_rollback: UNRECOVERABLE: "
			       "@ is missing. Backup: @autosnap-rollback-backup-%s  "
			       "Staging: @autosnap-new-%s  "
			       "DO NOT REBOOT until @ is restored manually.",
			       ts, ts);
		} else {
			/* @ restored from backup; clean up staging */
			bdfs_exec_btrfs_subvol_delete(d, new_staging);
			syslog(LOG_ERR,
			       "bdfs: autosnap_rollback: recovered — @ restored "
			       "from backup. Staging subvolume deleted.");
		}
		goto out_umount;
	}

	syslog(LOG_INFO,
	       "bdfs: autosnap_rollback: rolled back to '%s'; "
	       "reboot required to activate new @",
	       snap_name);

out_umount:
	if (umount2(tmpdir, MNT_DETACH) < 0)
		syslog(LOG_WARNING,
		       "bdfs: autosnap_rollback: umount %s: %m "
		       "(will be cleaned up on reboot)",
		       tmpdir);
	rmdir(tmpdir);
	return ret;
}

/* ── Mount blend layer — userspace fuse-overlayfs fallback ──────────────── */

/*
 * bdfs_job_mount_blend_userspace - Mount a blend namespace using
 * fuse-overlayfs instead of the bdfs_blend kernel module.
 *
 * This is the primary path when the kernel module is not loaded (ENODEV
 * from BDFS_IOC_MOUNT_BLEND) or when --userspace is passed explicitly.
 *
 * Steps:
 *   1. Create a private DwarFS FUSE mountpoint under state_dir.
 *   2. Mount the DwarFS image there via bdfs_exec_dwarfs_mount().
 *   3. Ensure the blend mountpoint and workdir exist.
 *   4. Invoke fuse-overlayfs:
 *        lowerdir = <private dwarfs fuse mount>
 *        upperdir = <btrfs_upper subvolume>
 *        workdir  = <work_dir>
 *        merged   = <blend_mount>
 *   5. Track both mounts in the mount table so umount tears them down
 *      in the correct order (overlay first, then dwarfs FUSE).
 */
int bdfs_job_mount_blend_userspace(struct bdfs_daemon *d, struct bdfs_job *job)
{
	const struct bdfs_job *j = job;
	char lower_fuse_mnt[BDFS_PATH_MAX];
	int  ret;

	/*
	 * Step 1: private DwarFS FUSE mountpoint.
	 * Named after the blend mountpoint to make it identifiable in
	 * process listings and /proc/mounts.
	 */
	{
		/* Derive a short tag from the blend mount basename */
		const char *base = strrchr(j->mount_blend_userspace.blend_mount,
					   '/');
		base = base ? base + 1 : j->mount_blend_userspace.blend_mount;
		snprintf(lower_fuse_mnt, sizeof(lower_fuse_mnt),
			 "%s/.bdfs_lower_%s", d->cfg.state_dir, base);
	}

	if (mkdir(lower_fuse_mnt, 0700) < 0 && errno != EEXIST) {
		syslog(LOG_ERR,
		       "bdfs: blend-us: mkdir lower fuse mnt %s: %m",
		       lower_fuse_mnt);
		return -errno;
	}

	/* Step 2: mount DwarFS image at the private mountpoint */
	ret = bdfs_exec_dwarfs_mount(d,
		j->mount_blend_userspace.dwarfs_image,
		lower_fuse_mnt,
		j->mount_blend_userspace.cache_size_mb);
	if (ret) {
		syslog(LOG_ERR,
		       "bdfs: blend-us: dwarfs mount %s failed: %d",
		       j->mount_blend_userspace.dwarfs_image, ret);
		rmdir(lower_fuse_mnt);
		return ret;
	}

	/* Step 3: ensure blend mountpoint and workdir exist */
	if (mkdir(j->mount_blend_userspace.blend_mount, 0755) < 0
	    && errno != EEXIST) {
		syslog(LOG_ERR,
		       "bdfs: blend-us: mkdir blend mnt %s: %m",
		       j->mount_blend_userspace.blend_mount);
		bdfs_exec_dwarfs_umount(d, lower_fuse_mnt);
		rmdir(lower_fuse_mnt);
		return -errno;
	}

	if (j->mount_blend_userspace.work_dir[0]) {
		if (mkdir(j->mount_blend_userspace.work_dir, 0700) < 0
		    && errno != EEXIST) {
			syslog(LOG_ERR,
			       "bdfs: blend-us: mkdir workdir %s: %m",
			       j->mount_blend_userspace.work_dir);
			bdfs_exec_dwarfs_umount(d, lower_fuse_mnt);
			rmdir(lower_fuse_mnt);
			return -errno;
		}
	}

	/* Step 4: invoke fuse-overlayfs */
	ret = bdfs_exec_fuse_overlayfs(d,
		lower_fuse_mnt,
		j->mount_blend_userspace.btrfs_upper,
		j->mount_blend_userspace.work_dir,
		j->mount_blend_userspace.blend_mount);
	if (ret) {
		syslog(LOG_ERR,
		       "bdfs: blend-us: fuse-overlayfs failed: %d", ret);
		bdfs_exec_dwarfs_umount(d, lower_fuse_mnt);
		rmdir(lower_fuse_mnt);
		return ret;
	}

	/* Step 5: track both mounts */
	bdfs_mount_track_userspace_blend(d,
		j->partition_uuid,
		j->mount_blend_userspace.blend_mount,
		lower_fuse_mnt);

	syslog(LOG_INFO,
	       "bdfs: blend-us: mounted at %s "
	       "(lower=%s upper=%s)",
	       j->mount_blend_userspace.blend_mount,
	       lower_fuse_mnt,
	       j->mount_blend_userspace.btrfs_upper);
	return 0;
}
