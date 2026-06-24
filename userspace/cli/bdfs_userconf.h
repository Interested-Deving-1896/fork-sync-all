/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * bdfs_userconf.h - User-level configuration (~/.config/bdfs/bdfs.conf)
 */
#ifndef _BDFS_USERCONF_H
#define _BDFS_USERCONF_H

#include <stdint.h>
#include "../../include/uapi/bdfs_ioctl.h"

#define BDFS_USERCONF_MAX_SOURCES 32

struct bdfs_userconf {
	char     snapshot_dir[512];  /* default: ~/.snapshots */
	char     archive_dir[512];   /* default: ~/.snapshots/archive */
	uint32_t keep;               /* default: 10 */
	uint32_t auto_demote_keep;   /* 0 = disabled */
	uint32_t compression;        /* BDFS_COMPRESS_* */
	char     sources[BDFS_USERCONF_MAX_SOURCES][512];
	uint32_t source_count;
};

void bdfs_userconf_init(struct bdfs_userconf *cfg);
int  bdfs_userconf_load(struct bdfs_userconf *cfg);
int  bdfs_userconf_ensure_dir(void);
int  bdfs_userconf_write_default(void);

#endif /* _BDFS_USERCONF_H */
