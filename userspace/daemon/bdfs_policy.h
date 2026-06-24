/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * bdfs_policy.h - Auto-demote policy engine
 *
 * The policy engine runs as a background thread in the daemon.  It
 * periodically scans registered BTRFS-backed partitions and demotes
 * subvolumes that match configured rules to DwarFS images.
 *
 * Rules are defined in /etc/bdfs/bdfs.conf under [policy] sections,
 * or via the bdfs CLI:
 *
 *   bdfs policy add --partition <uuid> --age-days 30
 *                   --compression zstd --readonly
 *                   [--name-pattern "snap_*"]
 *                   [--min-size-mb 100]
 *                   [--delete-after-demote]
 *
 * The engine checks subvolume atime/mtime against the configured age
 * threshold.  Subvolumes that have not been accessed for longer than
 * age_days are automatically demoted.
 */

#ifndef _BDFS_POLICY_H
#define _BDFS_POLICY_H

#include <stdint.h>
#include <stdbool.h>
#include <pthread.h>
#include <sys/queue.h>
#include "bdfs_daemon.h"

#define BDFS_POLICY_MAX_PATTERN  256
#define BDFS_POLICY_DEFAULT_INTERVAL_S  3600   /* scan every hour */

/* A single auto-demote rule */
struct bdfs_policy_rule {
	TAILQ_ENTRY(bdfs_policy_rule) entry;

	uint64_t    rule_id;
	uint8_t     partition_uuid[16];     /* target BTRFS-backed partition */

	/* Trigger conditions (all must match) */
	uint32_t    age_days;               /* demote if not accessed for N days */
	uint64_t    min_size_bytes;         /* only demote if subvol >= this size */
	char        name_pattern[BDFS_POLICY_MAX_PATTERN]; /* fnmatch pattern, "" = all */

	/* Demote parameters */
	uint32_t    compression;            /* enum bdfs_dwarfs_compression */
	bool        readonly;               /* make imported subvol read-only */
	bool        delete_after_demote;    /* remove BTRFS subvol after image created */

	bool        enabled;
};

TAILQ_HEAD(bdfs_policy_list, bdfs_policy_rule);

/* Policy engine state */
struct bdfs_policy_engine {
	struct bdfs_daemon     *daemon;
	pthread_t               thread;
	pthread_mutex_t         rules_lock;
	struct bdfs_policy_list rules;
	uint64_t                next_rule_id;
	uint32_t                scan_interval_s;
	bool                    running;

	/* Statistics */
	uint64_t                total_demotes;
	uint64_t                total_bytes_freed;
	time_t                  last_scan_time;
};

/* Lifecycle */
int  bdfs_policy_init(struct bdfs_policy_engine *pe, struct bdfs_daemon *d);
void bdfs_policy_shutdown(struct bdfs_policy_engine *pe);

/* Rule management */
uint64_t bdfs_policy_add_rule(struct bdfs_policy_engine *pe,
			      const struct bdfs_policy_rule *rule);
int      bdfs_policy_remove_rule(struct bdfs_policy_engine *pe,
				 uint64_t rule_id);
int      bdfs_policy_list_rules(struct bdfs_policy_engine *pe,
				struct bdfs_policy_rule *out,
				uint32_t capacity,
				uint32_t *count_out);

/* Trigger a manual scan (also called by the background thread) */
int bdfs_policy_scan(struct bdfs_policy_engine *pe);

#endif /* _BDFS_POLICY_H */
