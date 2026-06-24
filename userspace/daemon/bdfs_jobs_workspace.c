// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * bdfs_jobs_workspace.c - Workspace shutdown lifecycle hook
 *
 * Implements BDFS_JOB_WORKSPACE_SHUTDOWN, which runs the appropriate bdfs
 * operation before a workspace container is stopped:
 *
 *   BDFS_WS_SHUTDOWN_PAUSE  — take a read-only BTRFS snapshot of the
 *                             workspace subvolume so the state at pause
 *                             time is recoverable. Optionally prunes old
 *                             snapshots keeping the N most recent.
 *
 *   BDFS_WS_SHUTDOWN_DELETE — demote the workspace subvolume to a DwarFS
 *                             archive before the container is destroyed.
 *
 *   BDFS_WS_SHUTDOWN_STOP   — no-op; the workspace is stopping normally
 *                             with no state preservation required.
 *
 * All operations are best-effort: failures are logged via syslog but do
 * not propagate to the caller. The workspace must stop regardless.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>

#include "bdfs_daemon.h"
#include "bdfs_shutdown_log.h"

/* Milliseconds elapsed since start_ts (struct timespec) */
static long long elapsed_ms(const struct timespec *start)
{
	struct timespec now;
	clock_gettime(CLOCK_MONOTONIC, &now);
	return (long long)(now.tv_sec  - start->tv_sec)  * 1000
	     + (long long)(now.tv_nsec - start->tv_nsec) / 1000000;
}

/* Maximum time (seconds) allowed for a workspace demote operation.
 * Large workspaces on slow disks can take tens of minutes to compress. */
#define WS_DEMOTE_TIMEOUT_S  (45 * 60)

/* ── Helpers ─────────────────────────────────────────────────────────────── */

/*
 * derive_image_path - build the .dwarfs archive path from the workspace path.
 *
 * If job->workspace_shutdown.image_path is non-empty it is used as-is.
 * Otherwise the archive is placed alongside the subvolume as
 * "<workspace_path>.dwarfs".
 */
static void derive_image_path(const struct bdfs_job *job,
			      char *out, size_t outsz)
{
	const char *explicit = job->workspace_shutdown.image_path;
	if (explicit[0] != '\0') {
		snprintf(out, outsz, "%s", explicit);
	} else {
		snprintf(out, outsz, "%s.dwarfs",
			 job->workspace_shutdown.workspace_path);
	}
}

/*
 * snapshot_name_for_pause - generate a timestamped snapshot name.
 *
 * Format: ws-snap-<unix_timestamp>
 * Placed as a sibling of the workspace subvolume:
 *   <parent_dir>/ws-snap-<ts>
 */
static void snapshot_path_for_pause(const char *workspace_path,
				    char *out, size_t outsz)
{
	char parent[BDFS_PATH_MAX];
	time_t now = time(NULL);

	/* Extract parent directory */
	snprintf(parent, sizeof(parent), "%s", workspace_path);
	char *slash = strrchr(parent, '/');
	if (slash && slash != parent)
		*slash = '\0';
	else
		snprintf(parent, sizeof(parent), ".");

	snprintf(out, outsz, "%s/ws-snap-%" PRId64,
		 parent, (int64_t)now);
}

/* ── Pause: BTRFS snapshot ───────────────────────────────────────────────── */

static int workspace_do_pause(struct bdfs_daemon *d,
			      const struct bdfs_job *job)
{
	const char *ws = job->workspace_shutdown.workspace_path;
	char snap_path[BDFS_PATH_MAX];
	struct timespec t0;
	clock_gettime(CLOCK_MONOTONIC, &t0);

	snapshot_path_for_pause(ws, snap_path, sizeof(snap_path));
	syslog(LOG_INFO, "bdfs: workspace pause: snapshotting %s → %s",
	       ws, snap_path);

	int ret = bdfs_exec_btrfs_snapshot(d, ws, snap_path, /*readonly=*/true);

	/* Log the event regardless of outcome */
	struct bdfs_shutdown_event ev = {0};
	ev.timestamp = time(NULL);
	ev.reason    = BDFS_WS_SHUTDOWN_PAUSE;
	ev.duration_ms = elapsed_ms(&t0);
	strncpy(ev.workspace_path, ws, BDFS_PATH_MAX - 1);
	strncpy(ev.archive_path, snap_path, BDFS_PATH_MAX - 1);

	if (ret) {
		ev.outcome = (ret == -ETIMEDOUT)
			     ? BDFS_SHUTDOWN_TIMEOUT : BDFS_SHUTDOWN_ERROR;
		snprintf(ev.error_msg, sizeof(ev.error_msg),
			 "btrfs snapshot failed: %d", ret);
		bdfs_shutdown_log_write(d, &ev);
		syslog(LOG_WARNING,
		       "bdfs: workspace pause: snapshot failed (non-fatal): %d",
		       ret);
		return ret;
	}

	ev.outcome = BDFS_SHUTDOWN_OK;
	bdfs_shutdown_log_write(d, &ev);
	syslog(LOG_INFO, "bdfs: workspace pause: snapshot complete → %s",
	       snap_path);

	/* Prune old snapshots if configured */
	uint32_t keep = job->workspace_shutdown.prune_keep;
	if (keep > 0) {
		struct bdfs_job *prune_job = bdfs_job_alloc(BDFS_JOB_PRUNE);
		if (!prune_job) {
			syslog(LOG_WARNING,
			       "bdfs: workspace pause: prune alloc failed (non-fatal)");
			return 0;
		}

		char parent[BDFS_PATH_MAX];
		snprintf(parent, sizeof(parent), "%s", ws);
		char *slash = strrchr(parent, '/');
		if (slash && slash != parent)
			*slash = '\0';
		else
			snprintf(parent, sizeof(parent), ".");

		snprintf(prune_job->prune.btrfs_mount,
			 sizeof(prune_job->prune.btrfs_mount), "%s", parent);
		snprintf(prune_job->prune.name_pattern,
			 sizeof(prune_job->prune.name_pattern), "ws-snap-*");
		prune_job->prune.keep_count = keep;
		prune_job->prune.flags = 0;
		prune_job->prune.demote_compression =
			job->workspace_shutdown.compression;

		int prune_ret = bdfs_job_prune(d, prune_job);
		bdfs_job_free(prune_job);
		if (prune_ret)
			syslog(LOG_WARNING,
			       "bdfs: workspace pause: prune failed (non-fatal): %d",
			       prune_ret);
	}

	return 0;
}

/* ── Delete: bdfs demote ─────────────────────────────────────────────────── */

/*
 * extract_cid_from_json - pull the "cid" string value out of the one-line
 * JSON object emitted by bdfs-pin-helper.
 *
 * Expected format: {"cid":"<CID>","cached":...,"size_bytes":...}
 * Writes at most outsz-1 bytes into out. Returns true on success.
 */
static bool extract_cid_from_json(const char *json, char *out, size_t outsz)
{
	const char *key = "\"cid\":\"";
	const char *p = strstr(json, key);
	if (!p)
		return false;
	p += strlen(key);
	const char *end = strchr(p, '"');
	if (!end)
		return false;
	size_t len = (size_t)(end - p);
	if (len == 0 || len >= outsz)
		return false;
	memcpy(out, p, len);
	out[len] = '\0';
	return true;
}

/*
 * pin_archive_to_ipfs - call bdfs-pin-helper as a subprocess and store the
 * resulting CID in cid_out.
 *
 * Best-effort: logs warnings on failure but does not propagate errors to the
 * caller. The workspace must be deleted regardless of whether pinning works.
 */
static void pin_archive_to_ipfs(struct bdfs_daemon *d,
				const char *image_path,
				char *cid_out, size_t cid_outsz)
{
	const char *helper = d->cfg.pin_helper_bin[0]
			     ? d->cfg.pin_helper_bin
			     : "bdfs-pin-helper";
	const char *kubo   = d->cfg.kubo_api[0]
			     ? d->cfg.kubo_api
			     : "http://127.0.0.1:5001";

	const char *argv[] = {
		helper,
		"--archive", image_path,
		"--kubo-api", kubo,
		NULL
	};

	/* Allow up to 30 minutes for large archives */
	const int pin_timeout_s = 1800;
	char json_buf[512] = {0};

	syslog(LOG_INFO, "bdfs: pin-helper: pinning %s via %s", image_path, kubo);

	int ret = bdfs_exec_capture_output(argv, pin_timeout_s,
					   json_buf, sizeof(json_buf));
	if (ret) {
		syslog(LOG_WARNING,
		       "bdfs: pin-helper: failed for %s (ret=%d, non-fatal)",
		       image_path, ret);
		return;
	}

	if (!extract_cid_from_json(json_buf, cid_out, cid_outsz)) {
		syslog(LOG_WARNING,
		       "bdfs: pin-helper: could not parse CID from output: %.128s",
		       json_buf);
		return;
	}

	syslog(LOG_INFO, "bdfs: pin-helper: pinned %s → %s", image_path, cid_out);
}

static int workspace_do_delete(struct bdfs_daemon *d,
			       const struct bdfs_job *job)
{
	const char *ws = job->workspace_shutdown.workspace_path;
	char image_path[BDFS_PATH_MAX];
	struct timespec t0;
	clock_gettime(CLOCK_MONOTONIC, &t0);

	derive_image_path(job, image_path, sizeof(image_path));
	syslog(LOG_INFO,
	       "bdfs: workspace delete: demoting %s → %s (compression=%u)",
	       ws, image_path, job->workspace_shutdown.compression);

	/*
	 * Call bdfs_exec_mkdwarfs directly on the workspace path rather than
	 * going through BDFS_JOB_EXPORT_TO_DWARFS (which requires a registered
	 * partition and a valid subvol_id). mkdwarfs -i <dir> works on any
	 * readable directory. block_size_bits=0 → default (22 = 4 MiB).
	 */
	int ret = bdfs_exec_mkdwarfs(d,
				     ws,
				     image_path,
				     job->workspace_shutdown.compression,
				     /*block_size_bits=*/0,
				     /*worker_threads=*/0);

	/* Log the event */
	struct bdfs_shutdown_event ev = {0};
	ev.timestamp = time(NULL);
	ev.reason    = BDFS_WS_SHUTDOWN_DELETE;
	ev.duration_ms = elapsed_ms(&t0);
	strncpy(ev.workspace_path, ws,         BDFS_PATH_MAX - 1);
	strncpy(ev.archive_path,   image_path, BDFS_PATH_MAX - 1);

	if (ret) {
		ev.outcome = (ret == -ETIMEDOUT)
			     ? BDFS_SHUTDOWN_TIMEOUT : BDFS_SHUTDOWN_ERROR;
		snprintf(ev.error_msg, sizeof(ev.error_msg),
			 "mkdwarfs failed: %d", ret);
		bdfs_shutdown_log_write(d, &ev);
		syslog(LOG_WARNING,
		       "bdfs: workspace delete: mkdwarfs failed (non-fatal): %d",
		       ret);
		return ret;
	}

	/*
	 * Pin the archive to IPFS. Best-effort: a failure here does not
	 * prevent the shutdown log entry from being written or the workspace
	 * from being deleted. archive_cid stays "" if pinning is unavailable.
	 */
	pin_archive_to_ipfs(d, image_path, ev.archive_cid, sizeof(ev.archive_cid));

	ev.outcome = BDFS_SHUTDOWN_OK;
	bdfs_shutdown_log_write(d, &ev);
	syslog(LOG_INFO, "bdfs: workspace delete: demote complete → %s (cid=%s)",
	       image_path, ev.archive_cid[0] ? ev.archive_cid : "(not pinned)");
	return 0;
}

/* ── Entry point ─────────────────────────────────────────────────────────── */

int bdfs_job_workspace_shutdown(struct bdfs_daemon *d, struct bdfs_job *job)
{
	const char *ws = job->workspace_shutdown.workspace_path;

	if (ws[0] == '\0') {
		syslog(LOG_WARNING,
		       "bdfs: workspace_shutdown: empty workspace_path, skipping");
		return 0;
	}

	switch (job->workspace_shutdown.reason) {
	case BDFS_WS_SHUTDOWN_PAUSE:
		return workspace_do_pause(d, job);

	case BDFS_WS_SHUTDOWN_DELETE:
		return workspace_do_delete(d, job);

	case BDFS_WS_SHUTDOWN_STOP:
		syslog(LOG_DEBUG,
		       "bdfs: workspace_shutdown: reason=stop, no-op for %s", ws);
		return 0;

	default:
		syslog(LOG_WARNING,
		       "bdfs: workspace_shutdown: unknown reason %u for %s",
		       job->workspace_shutdown.reason, ws);
		return 0;
	}
}
