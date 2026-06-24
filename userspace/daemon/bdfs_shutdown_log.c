// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * bdfs_shutdown_log.c - Structured workspace shutdown event log
 *
 * Appends one JSON line per workspace shutdown event to a configurable log
 * file (default: /var/log/bdfs/workspace-shutdown.jsonl).
 *
 * Each line is a self-contained JSON object:
 *
 *   {
 *     "ts":             "<ISO-8601 UTC timestamp>",
 *     "workspace_path": "<path>",
 *     "reason":         "pause"|"delete"|"stop",
 *     "outcome":        "ok"|"error"|"timeout",
 *     "duration_ms":    <integer>,
 *     "archive_path":   "<path or null>",
 *     "archive_cid":    "<IPFS CID or null>",
 *     "error":          "<message or null>"
 *   }
 *
 * The file is opened in append mode on each write and closed immediately,
 * so it is safe to rotate with logrotate(8) using copytruncate.
 *
 * Thread safety: bdfs_shutdown_log_write is protected by a mutex so
 * concurrent worker threads do not interleave partial writes.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>

#include "bdfs_daemon.h"
#include "bdfs_shutdown_log.h"

/* Default log path when cfg.shutdown_log_path is empty */
#define BDFS_SHUTDOWN_LOG_DEFAULT "/var/log/bdfs/workspace-shutdown.jsonl"

static pthread_mutex_t log_mutex = PTHREAD_MUTEX_INITIALIZER;

/*
 * bdfs_shutdown_log_write - append one JSON event line to the shutdown log.
 *
 * @d            daemon handle (for cfg.shutdown_log_path)
 * @ev           event to record
 *
 * Non-fatal: failures are logged to syslog but do not propagate.
 */
void bdfs_shutdown_log_write(struct bdfs_daemon *d,
			     const struct bdfs_shutdown_event *ev)
{
	const char *log_path = (d->cfg.shutdown_log_path[0])
			       ? d->cfg.shutdown_log_path
			       : BDFS_SHUTDOWN_LOG_DEFAULT;

	/* Format ISO-8601 UTC timestamp */
	char ts[32];
	struct tm *tm = gmtime(&ev->timestamp);
	strftime(ts, sizeof(ts), "%Y-%m-%dT%H:%M:%SZ", tm);

	/* Map reason code to string */
	const char *reason_str;
	switch (ev->reason) {
	case BDFS_WS_SHUTDOWN_PAUSE:  reason_str = "pause";  break;
	case BDFS_WS_SHUTDOWN_DELETE: reason_str = "delete"; break;
	default:                      reason_str = "stop";   break;
	}

	/* Map outcome to string */
	const char *outcome_str;
	switch (ev->outcome) {
	case BDFS_SHUTDOWN_OK:      outcome_str = "ok";      break;
	case BDFS_SHUTDOWN_TIMEOUT: outcome_str = "timeout"; break;
	default:                    outcome_str = "error";   break;
	}

	/* Build JSON line — all string fields are sanitised (no embedded quotes) */
	char line[4096];
	int n = snprintf(line, sizeof(line),
		"{\"ts\":\"%s\","
		"\"workspace_path\":\"%s\","
		"\"reason\":\"%s\","
		"\"outcome\":\"%s\","
		"\"duration_ms\":%lld,"
		"\"archive_path\":%s%s%s,"
		"\"archive_cid\":%s%s%s,"
		"\"error\":%s%s%s}\n",
		ts,
		ev->workspace_path,
		reason_str,
		outcome_str,
		(long long)ev->duration_ms,
		/* archive_path: null or quoted string */
		ev->archive_path[0] ? "\"" : "",
		ev->archive_path[0] ? ev->archive_path : "null",
		ev->archive_path[0] ? "\"" : "",
		/* archive_cid: null or quoted string */
		ev->archive_cid[0] ? "\"" : "",
		ev->archive_cid[0] ? ev->archive_cid : "null",
		ev->archive_cid[0] ? "\"" : "",
		/* error: null or quoted string */
		ev->error_msg[0] ? "\"" : "",
		ev->error_msg[0] ? ev->error_msg : "null",
		ev->error_msg[0] ? "\"" : "");

	if (n <= 0 || (size_t)n >= sizeof(line)) {
		syslog(LOG_WARNING, "bdfs: shutdown log: line truncated for %s",
		       ev->workspace_path);
	}

	pthread_mutex_lock(&log_mutex);

	/* Ensure log directory exists */
	char dir[512];
	strncpy(dir, log_path, sizeof(dir) - 1);
	char *slash = strrchr(dir, '/');
	if (slash && slash != dir) {
		*slash = '\0';
		if (mkdir(dir, 0755) < 0 && errno != EEXIST)
			syslog(LOG_WARNING, "bdfs: shutdown log dir %s: %m", dir);
	}

	FILE *f = fopen(log_path, "ae"); /* append, O_CLOEXEC */
	if (!f) {
		syslog(LOG_WARNING, "bdfs: shutdown log open %s: %m", log_path);
		pthread_mutex_unlock(&log_mutex);
		return;
	}

	fputs(line, f);
	fflush(f);
	fclose(f);

	pthread_mutex_unlock(&log_mutex);
}
