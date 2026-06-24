/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * bdfs_shutdown_log.h - Workspace shutdown event log API
 */
#ifndef _BDFS_SHUTDOWN_LOG_H
#define _BDFS_SHUTDOWN_LOG_H

#include <time.h>
#include "bdfs_daemon.h"

/* Outcome codes for bdfs_shutdown_event.outcome */
#define BDFS_SHUTDOWN_OK      0
#define BDFS_SHUTDOWN_ERROR   1
#define BDFS_SHUTDOWN_TIMEOUT 2

/*
 * bdfs_shutdown_event - one workspace shutdown lifecycle event.
 *
 * Populated by bdfs_job_workspace_shutdown before calling
 * bdfs_shutdown_log_write.
 */
struct bdfs_shutdown_event {
	time_t    timestamp;                    /* wall clock at job start     */
	char      workspace_path[BDFS_PATH_MAX];
	uint32_t  reason;                       /* BDFS_WS_SHUTDOWN_*          */
	int       outcome;                      /* BDFS_SHUTDOWN_*             */
	long long duration_ms;                  /* wall time for the operation */
	char      archive_path[BDFS_PATH_MAX];  /* "" if not applicable        */
	char      archive_cid[256];             /* IPFS CID, "" if not pinned  */
	char      error_msg[512];               /* "" on success               */
};

void bdfs_shutdown_log_write(struct bdfs_daemon *d,
			     const struct bdfs_shutdown_event *ev);

#endif /* _BDFS_SHUTDOWN_LOG_H */
