// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * bdfs_mount_table.c - Active mount tracking with O(1) hash index
 *
 * Every mount the daemon manages (DwarFS FUSE, kernel blend, userspace blend)
 * is recorded in two containers:
 *
 *   d->mounts      TAILQ — ordered list for shutdown teardown and count.
 *   d->mounts_idx  open-addressing hash table keyed by mount_point string,
 *                  giving O(1) lookup in umount and untrack paths.
 *
 * All public functions acquire d->mounts_lock internally except
 * bdfs_mount_lookup(), which requires the caller to hold it (so the caller
 * can act on the result without a TOCTOU window).
 */
#define _GNU_SOURCE
#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>

#include "bdfs_daemon.h"

/* ── FNV-1a hash ─────────────────────────────────────────────────────────── */

static uint32_t fnv1a(const char *s)
{
	uint32_t h = 2166136261u;
	while (*s) {
		h ^= (uint8_t)*s++;
		h *= 16777619u;
	}
	return h;
}

static uint32_t slot_for(const char *mount_point)
{
	return fnv1a(mount_point) & (BDFS_MOUNT_HASH_SIZE - 1);
}

/* ── Hash index primitives (caller holds mounts_lock) ────────────────────── */

/*
 * idx_insert - Insert entry into the hash index.
 *
 * Uses linear probing.  Reuses tombstone slots before empty ones so the
 * table doesn't fill with tombstones after heavy churn.
 */
static void idx_insert(struct bdfs_mount_index *idx,
		       struct bdfs_mount_entry *entry)
{
	uint32_t start = slot_for(entry->mount_point);
	uint32_t i     = start;
	int      tomb  = -1; /* first tombstone seen */

	do {
		struct bdfs_mount_entry *s = idx->slots[i];
		if (s == NULL) {
			/* Empty slot — use tombstone if we passed one */
			idx->slots[tomb >= 0 ? (uint32_t)tomb : i] = entry;
			return;
		}
		if (s == BDFS_MOUNT_TOMBSTONE) {
			if (tomb < 0)
				tomb = (int)i;
		}
		i = (i + 1) & (BDFS_MOUNT_HASH_SIZE - 1);
	} while (i != start);

	/* Table full — should never happen given expected load factor */
	syslog(LOG_ERR, "bdfs: mount index full, cannot track %s",
	       entry->mount_point);
}

/*
 * idx_remove - Mark the slot for mount_point as a tombstone.
 *
 * Returns the removed entry pointer, or NULL if not found.
 */
static struct bdfs_mount_entry *idx_remove(struct bdfs_mount_index *idx,
					   const char *mount_point)
{
	uint32_t start = slot_for(mount_point);
	uint32_t i     = start;

	do {
		struct bdfs_mount_entry *s = idx->slots[i];
		if (s == NULL)
			return NULL; /* not found */
		if (s != BDFS_MOUNT_TOMBSTONE &&
		    strcmp(s->mount_point, mount_point) == 0) {
			idx->slots[i] = BDFS_MOUNT_TOMBSTONE;
			return s;
		}
		i = (i + 1) & (BDFS_MOUNT_HASH_SIZE - 1);
	} while (i != start);

	return NULL;
}

/* ── Public API ──────────────────────────────────────────────────────────── */

/*
 * bdfs_mount_lookup - O(1) lookup by mount_point.
 *
 * Caller must hold d->mounts_lock.
 * Returns the entry, or NULL if not tracked.
 */
struct bdfs_mount_entry *bdfs_mount_lookup(struct bdfs_daemon *d,
					   const char *mount_point)
{
	uint32_t start = slot_for(mount_point);
	uint32_t i     = start;
	struct bdfs_mount_index *idx = &d->mounts_idx;

	do {
		struct bdfs_mount_entry *s = idx->slots[i];
		if (s == NULL)
			return NULL;
		if (s != BDFS_MOUNT_TOMBSTONE &&
		    strcmp(s->mount_point, mount_point) == 0)
			return s;
		i = (i + 1) & (BDFS_MOUNT_HASH_SIZE - 1);
	} while (i != start);

	return NULL;
}

/*
 * bdfs_mount_track - Record a new DwarFS or kernel-blend mount.
 */
void bdfs_mount_track(struct bdfs_daemon *d, enum bdfs_mount_type type,
		      const uint8_t uuid[16], uint64_t image_id,
		      const char *mount_point)
{
	struct bdfs_mount_entry *e = calloc(1, sizeof(*e));
	if (!e) {
		syslog(LOG_ERR, "bdfs: mount_track: out of memory for %s",
		       mount_point);
		return;
	}

	e->type     = type;
	e->image_id = image_id;
	if (uuid)
		memcpy(e->partition_uuid, uuid, 16);
	strncpy(e->mount_point, mount_point, sizeof(e->mount_point) - 1);

	pthread_mutex_lock(&d->mounts_lock);
	TAILQ_INSERT_TAIL(&d->mounts, e, entry);
	idx_insert(&d->mounts_idx, e);
	pthread_mutex_unlock(&d->mounts_lock);

	syslog(LOG_DEBUG, "bdfs: tracking mount %s (type=%d)", mount_point,
	       (int)type);
}

/*
 * bdfs_mount_track_userspace_blend - Record a userspace blend mount.
 *
 * Stores both the merged mountpoint (blend_mount) and the private DwarFS
 * FUSE lower mountpoint (lower_fuse_mount) so umount can tear them down
 * in the correct order.  The hash index is keyed on blend_mount.
 */
void bdfs_mount_track_userspace_blend(struct bdfs_daemon *d,
				      const uint8_t uuid[16],
				      const char *blend_mount,
				      const char *lower_fuse_mount)
{
	struct bdfs_mount_entry *e = calloc(1, sizeof(*e));
	if (!e) {
		syslog(LOG_ERR,
		       "bdfs: mount_track_userspace_blend: out of memory");
		return;
	}

	e->type = BDFS_MNT_BLEND_USERSPACE;
	if (uuid)
		memcpy(e->partition_uuid, uuid, 16);
	strncpy(e->mount_point,      blend_mount,      sizeof(e->mount_point) - 1);
	strncpy(e->lower_fuse_mount, lower_fuse_mount, sizeof(e->lower_fuse_mount) - 1);

	pthread_mutex_lock(&d->mounts_lock);
	TAILQ_INSERT_TAIL(&d->mounts, e, entry);
	idx_insert(&d->mounts_idx, e);
	pthread_mutex_unlock(&d->mounts_lock);

	syslog(LOG_DEBUG,
	       "bdfs: tracking userspace blend %s (lower=%s)",
	       blend_mount, lower_fuse_mount);
}

/*
 * bdfs_mount_untrack - Remove a mount from both the TAILQ and hash index.
 *
 * Safe to call from any thread.  No-op if mount_point is not tracked.
 */
void bdfs_mount_untrack(struct bdfs_daemon *d, const char *mount_point)
{
	struct bdfs_mount_entry *e;

	pthread_mutex_lock(&d->mounts_lock);
	e = idx_remove(&d->mounts_idx, mount_point);
	if (e)
		TAILQ_REMOVE(&d->mounts, e, entry);
	pthread_mutex_unlock(&d->mounts_lock);

	if (e) {
		syslog(LOG_DEBUG, "bdfs: untracked mount %s", mount_point);
		free(e);
	} else {
		syslog(LOG_WARNING,
		       "bdfs: mount_untrack: %s not found", mount_point);
	}
}

/*
 * bdfs_mount_count - Return the number of currently tracked mounts.
 */
int bdfs_mount_count(struct bdfs_daemon *d)
{
	struct bdfs_mount_entry *e;
	int n = 0;

	pthread_mutex_lock(&d->mounts_lock);
	TAILQ_FOREACH(e, &d->mounts, entry)
		n++;
	pthread_mutex_unlock(&d->mounts_lock);

	return n;
}
