/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * bdfs_config.h - Daemon configuration file parser API
 */
#ifndef _BDFS_CONFIG_H
#define _BDFS_CONFIG_H

#include "bdfs_daemon.h"

/*
 * bdfs_config_load - parse a bdfs.conf file into *cfg.
 *
 * @path  path to the config file, or NULL for /etc/bdfs/bdfs.conf
 * @cfg   destination; caller must have zero-initialised it
 *
 * Returns 0 on success, -ENOENT if the file does not exist (not an error),
 * or -errno on read error.
 *
 * Call before bdfs_daemon_init() so that compiled-in defaults fill any
 * fields left zero/empty by the config file.
 */
int bdfs_config_load(const char *path, struct bdfs_daemon_config *cfg);

#endif /* _BDFS_CONFIG_H */
