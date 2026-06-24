// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * bdfs_exec.c - Tool execution helpers
 *
 * Wrappers around mkdwarfs, dwarfs, dwarfsextract, fuse-overlayfs, and
 * btrfs-progs.  Each function forks a child process, sets up pipes where
 * needed, and waits for completion.  Stdout/stderr are forwarded to syslog
 * when verbose mode is enabled.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sendfile.h>
#include <sys/wait.h>
#include <syslog.h>
#include <unistd.h>

#include "bdfs_daemon.h"

/* Compression algorithm name for mkdwarfs --compression flag */
static const char *compression_name(uint32_t c)
{
	switch (c) {
	case BDFS_COMPRESS_LZMA:   return "lzma";
	case BDFS_COMPRESS_ZSTD:   return "zstd";
	case BDFS_COMPRESS_LZ4:    return "lz4";
	case BDFS_COMPRESS_BROTLI: return "brotli";
	default:                   return "null";
	}
}

/*
 * bdfs_exec_wait - Fork, exec argv[], and wait for exit.
 * Returns 0 on success, -errno on fork failure, or the child exit code.
 */
int bdfs_exec_wait(const char *const argv[])
{
	pid_t pid;
	int   status;

	pid = fork();
	if (pid < 0)
		return -errno;

	if (pid == 0) {
		/* Child: redirect stdout/stderr to /dev/null unless verbose */
		int devnull = open("/dev/null", O_WRONLY);
		if (devnull >= 0) {
			dup2(devnull, STDOUT_FILENO);
			dup2(devnull, STDERR_FILENO);
			close(devnull);
		}
		execvp(argv[0], (char *const *)argv);
		_exit(127);
	}

	if (waitpid(pid, &status, 0) < 0)
		return -errno;
	if (WIFEXITED(status))
		return WEXITSTATUS(status) == 0 ? 0 : -EIO;
	return -EIO;
}

/* ── mkdwarfs ───────────────────────────────────────────────────────────── */

/*
 * bdfs_exec_mkdwarfs - Create a DwarFS image from a directory.
 *
 * Equivalent to:
 *   mkdwarfs -i <input_dir> -o <output_image>
 *            --compression <algo>
 *            --block-size-bits <bits>
 *            --num-workers <n>
 *            --categorize
 */
int bdfs_exec_mkdwarfs(struct bdfs_daemon *d, const char *input_dir,
		       const char *output_image, uint32_t compression,
		       uint32_t block_size_bits, int worker_threads)
{
	char bits_str[16], workers_str[16];
	const char *argv[32];
	int i = 0;

	snprintf(bits_str,    sizeof(bits_str),    "%u",
		 block_size_bits ? block_size_bits : 22);
	snprintf(workers_str, sizeof(workers_str), "%d",
		 worker_threads  ? worker_threads  : 4);

	argv[i++] = d->cfg.mkdwarfs_bin;
	argv[i++] = "-i";
	argv[i++] = input_dir;
	argv[i++] = "-o";
	argv[i++] = output_image;
	argv[i++] = "--compression";
	argv[i++] = compression_name(compression);
	argv[i++] = "--block-size-bits";
	argv[i++] = bits_str;
	argv[i++] = "--num-workers";
	argv[i++] = workers_str;
	argv[i++] = "--categorize";
	argv[i++] = NULL;

	int timeout_s = d->cfg.mkdwarfs_timeout_s > 0
			? d->cfg.mkdwarfs_timeout_s : 2700;

	syslog(LOG_INFO,
	       "bdfs: mkdwarfs %s → %s (compression=%s, timeout=%ds)",
	       input_dir, output_image, compression_name(compression),
	       timeout_s);

	int ret = bdfs_exec_wait_timeout(argv, timeout_s);
	if (ret == -ETIMEDOUT)
		syslog(LOG_ERR, "bdfs: mkdwarfs timed out after %ds for %s",
		       timeout_s, input_dir);
	return ret;
}

/* ── dwarfsextract ──────────────────────────────────────────────────────── */

/*
 * bdfs_exec_dwarfsextract - Extract a DwarFS image to a directory.
 *
 * Equivalent to:
 *   dwarfsextract -i <image_path> -o <output_dir>
 */
int bdfs_exec_dwarfsextract(struct bdfs_daemon *d, const char *image_path,
			    const char *output_dir)
{
	const char *argv[] = {
		d->cfg.dwarfsextract_bin,
		"-i", image_path,
		"-o", output_dir,
		NULL
	};
	syslog(LOG_INFO, "bdfs: dwarfsextract %s → %s", image_path, output_dir);
	return bdfs_exec_wait(argv);
}

/* ── dwarfs FUSE mount ──────────────────────────────────────────────────── */

/*
 * bdfs_exec_dwarfs_mount - FUSE-mount a DwarFS image.
 *
 * Equivalent to:
 *   dwarfs <image_path> <mount_point> -o cache_size=<n>m
 *
 * The dwarfs FUSE driver runs in the background by default.
 */
int bdfs_exec_dwarfs_mount(struct bdfs_daemon *d, const char *image_path,
			   const char *mount_point, uint32_t cache_mb)
{
	char cache_opt[64];
	const char *argv[16];
	int i = 0;

	snprintf(cache_opt, sizeof(cache_opt), "cache_size=%um",
		 cache_mb ? cache_mb : 256);

	argv[i++] = d->cfg.dwarfs_bin;
	argv[i++] = image_path;
	argv[i++] = mount_point;
	argv[i++] = "-o";
	argv[i++] = cache_opt;
	argv[i++] = NULL;

	syslog(LOG_INFO, "bdfs: dwarfs mount %s → %s (cache=%um)",
	       image_path, mount_point, cache_mb);
	return bdfs_exec_wait(argv);
}

/* ── dwarfs FUSE unmount ────────────────────────────────────────────────── */

int bdfs_exec_dwarfs_umount(struct bdfs_daemon *d, const char *mount_point)
{
	const char *argv[] = { "fusermount", "-u", mount_point, NULL };
	(void)d;
	syslog(LOG_INFO, "bdfs: fusermount -u %s", mount_point);
	return bdfs_exec_wait(argv);
}

/* ── fuse-overlayfs ─────────────────────────────────────────────────────── */

/*
 * bdfs_exec_fuse_overlayfs - Mount a fuse-overlayfs overlay.
 *
 * Equivalent to:
 *   fuse-overlayfs \
 *     -o lowerdir=<lower>,upperdir=<upper>,workdir=<work> \
 *     <merged>
 *
 * fuse-overlayfs runs in the foreground by default; we pass -f so it
 * daemonises itself after the mount succeeds (same behaviour as the dwarfs
 * FUSE driver).  If the binary is not in cfg.fuse_overlayfs_bin we fall
 * back to searching PATH for "fuse-overlayfs".
 */
int bdfs_exec_fuse_overlayfs(struct bdfs_daemon *d, const char *lower,
			     const char *upper, const char *work,
			     const char *merged)
{
	char opt[BDFS_PATH_MAX * 3 + 64];
	const char *bin;
	const char *argv[16];
	int i = 0;

	bin = (d->cfg.fuse_overlayfs_bin[0])
		? d->cfg.fuse_overlayfs_bin
		: "fuse-overlayfs";

	snprintf(opt, sizeof(opt),
		 "lowerdir=%s,upperdir=%s,workdir=%s",
		 lower, upper, work);

	argv[i++] = bin;
	argv[i++] = "-o";
	argv[i++] = opt;
	argv[i++] = merged;
	argv[i++] = NULL;

	syslog(LOG_INFO,
	       "bdfs: fuse-overlayfs lower=%s upper=%s work=%s → %s",
	       lower, upper, work, merged);
	return bdfs_exec_wait(argv);
}

/* ── btrfs send ─────────────────────────────────────────────────────────── */

/*
 * bdfs_exec_btrfs_send - Start a `btrfs send` process and return the read
 * end of its output pipe.
 *
 * The caller is responsible for reading from *pipe_read_fd_out and closing
 * it when done.  The child process is reaped by the caller via waitpid on
 * the returned pid (stored in *child_pid_out).
 *
 * Equivalent to:
 *   btrfs send <subvol_path>  (stdout → pipe)
 */
int bdfs_exec_btrfs_send(struct bdfs_daemon *d, const char *subvol_path,
			 int *pipe_read_fd_out)
{
	return bdfs_exec_btrfs_send_incremental(d, subvol_path, NULL,
						pipe_read_fd_out);
}

/*
 * bdfs_exec_btrfs_send_incremental - Start a `btrfs send` process,
 * optionally with a parent snapshot for incremental sends.
 *
 * When parent_snap_path is non-NULL and non-empty, passes `-p <parent>` to
 * btrfs-send, producing a delta stream relative to the parent snapshot.
 * This dramatically reduces the size of the send stream (and therefore the
 * resulting DwarFS image) when only a small portion of the subvolume changed.
 *
 * Equivalent to:
 *   btrfs send [-p <parent>] <subvol_path>  (stdout → pipe)
 */
int bdfs_exec_btrfs_send_incremental(struct bdfs_daemon *d,
				     const char *subvol_path,
				     const char *parent_snap_path,
				     int *pipe_read_fd_out)
{
	int    pipefd[2];
	pid_t  pid;

	if (pipe2(pipefd, O_CLOEXEC) < 0)
		return -errno;

	pid = fork();
	if (pid < 0) {
		close(pipefd[0]);
		close(pipefd[1]);
		return -errno;
	}

	if (pid == 0) {
		close(pipefd[0]);
		dup2(pipefd[1], STDOUT_FILENO);
		close(pipefd[1]);

		if (parent_snap_path && parent_snap_path[0]) {
			execlp(d->cfg.btrfs_bin, "btrfs", "send",
			       "-p", parent_snap_path, subvol_path, NULL);
		} else {
			execlp(d->cfg.btrfs_bin, "btrfs", "send",
			       subvol_path, NULL);
		}
		_exit(127);
	}

	close(pipefd[1]);
	*pipe_read_fd_out = pipefd[0];

	if (parent_snap_path && parent_snap_path[0])
		syslog(LOG_INFO, "bdfs: btrfs send -p %s %s (pid=%d)",
		       parent_snap_path, subvol_path, pid);
	else
		syslog(LOG_INFO, "bdfs: btrfs send %s (pid=%d)",
		       subvol_path, pid);

	return (int)pid;
}

/* ── btrfs receive ──────────────────────────────────────────────────────── */

/*
 * bdfs_exec_btrfs_receive - Start a `btrfs receive` process reading from
 * a pipe.
 *
 * Equivalent to:
 *   btrfs receive <dest_dir>  (stdin ← pipe)
 */
int bdfs_exec_btrfs_receive(struct bdfs_daemon *d, const char *dest_dir,
			    int pipe_read_fd)
{
	pid_t pid;
	int   status;

	pid = fork();
	if (pid < 0)
		return -errno;

	if (pid == 0) {
		dup2(pipe_read_fd, STDIN_FILENO);
		execlp(d->cfg.btrfs_bin, "btrfs", "receive", dest_dir, NULL);
		_exit(127);
	}

	if (waitpid(pid, &status, 0) < 0)
		return -errno;

	syslog(LOG_INFO, "bdfs: btrfs receive %s (exit=%d)",
	       dest_dir, WEXITSTATUS(status));
	return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : -EIO;
}

/* ── btrfs subvolume snapshot ───────────────────────────────────────────── */

int bdfs_exec_btrfs_snapshot(struct bdfs_daemon *d, const char *source_subvol,
			     const char *dest_path, bool readonly)
{
	const char *argv[8];
	int i = 0;

	argv[i++] = d->cfg.btrfs_bin;
	argv[i++] = "subvolume";
	argv[i++] = "snapshot";
	if (readonly)
		argv[i++] = "-r";
	argv[i++] = source_subvol;
	argv[i++] = dest_path;
	argv[i++] = NULL;

	syslog(LOG_INFO, "bdfs: btrfs snapshot %s → %s (ro=%d)",
	       source_subvol, dest_path, readonly);
	return bdfs_exec_wait(argv);
}

/* ── btrfs subvolume create ─────────────────────────────────────────────── */

int bdfs_exec_btrfs_subvol_create(struct bdfs_daemon *d, const char *path)
{
	const char *argv[] = {
		d->cfg.btrfs_bin, "subvolume", "create", path, NULL
	};
	syslog(LOG_INFO, "bdfs: btrfs subvolume create %s", path);
	return bdfs_exec_wait(argv);
}

/* ── btrfs subvolume delete ─────────────────────────────────────────────── */

int bdfs_exec_btrfs_subvol_delete(struct bdfs_daemon *d, const char *path)
{
	const char *argv[] = {
		d->cfg.btrfs_bin, "subvolume", "delete", path, NULL
	};
	syslog(LOG_INFO, "bdfs: btrfs subvolume delete %s", path);
	return bdfs_exec_wait(argv);
}

/*
 * bdfs_exec_wait_timeout - fork, exec argv[], wait up to timeout_s seconds.
 *
 * Polls with WNOHANG every 500 ms. On timeout: SIGTERM, 5 s grace, SIGKILL.
 * Returns 0 on success, -ETIMEDOUT on timeout, -errno on fork error, -EIO
 * on non-zero exit or signal termination.
 */
int bdfs_exec_wait_timeout(const char *const argv[], int timeout_s)
{
	pid_t pid;
	int   status;
	int   elapsed_ms = 0;
	const int poll_ms = 500;
	const int grace_ms = 5000;

	pid = fork();
	if (pid < 0)
		return -errno;
	if (pid == 0) {
		int devnull = open("/dev/null", O_WRONLY);
		if (devnull >= 0) {
			dup2(devnull, STDOUT_FILENO);
			dup2(devnull, STDERR_FILENO);
			close(devnull);
		}
		execvp(argv[0], (char *const *)argv);
		_exit(127);
	}

	while (elapsed_ms < timeout_s * 1000) {
		struct timespec ts = { 0, poll_ms * 1000000L };
		nanosleep(&ts, NULL);
		elapsed_ms += poll_ms;
		pid_t r = waitpid(pid, &status, WNOHANG);
		if (r < 0) return -errno;
		if (r > 0) {
			if (WIFEXITED(status))
				return WEXITSTATUS(status) == 0 ? 0 : -EIO;
			return -EIO;
		}
	}

	syslog(LOG_WARNING,
	       "bdfs: exec timeout (%ds) — SIGTERM pid %d", timeout_s, (int)pid);
	kill(pid, SIGTERM);
	for (int g = 0; g < grace_ms; g += poll_ms) {
		struct timespec ts = { 0, poll_ms * 1000000L };
		nanosleep(&ts, NULL);
		if (waitpid(pid, &status, WNOHANG) > 0)
			return -ETIMEDOUT;
	}
	syslog(LOG_ERR, "bdfs: SIGKILL pid %d", (int)pid);
	kill(pid, SIGKILL);
	waitpid(pid, &status, 0);
	return -ETIMEDOUT;
}

