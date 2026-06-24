// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * bdfs_btrfs_part.c - BTRFS-backed partition backend
 *
 * A BTRFS-backed partition is a live BTRFS filesystem that stores DwarFS
 * image files as regular files.  This gives DwarFS images:
 *   - Copy-on-Write semantics (no partial-write corruption)
 *   - Per-file checksumming (data integrity)
 *   - Snapshot capability (point-in-time copies of image collections)
 *   - Transparent compression of image metadata via BTRFS compression
 *
 * Operations:
 *   1. Store a DwarFS image file onto the BTRFS partition.
 *   2. Import a DwarFS image into a new BTRFS subvolume (via dwarfsextract).
 *   3. Snapshot the BTRFS subvolume containing a DwarFS image.
 *   4. List subvolumes and snapshots on the partition.
 *
 * The kernel module validates requests and coordinates with the bdfs daemon
 * for operations that require userspace tools (btrfs-progs, dwarfsextract).
 */

#include <linux/module.h>
#include <linux/slab.h>
#include <linux/uaccess.h>
#include <linux/mutex.h>
#include <linux/list.h>
#include <linux/uuid.h>
#include <linux/fs.h>
#include <linux/file.h>
#include <linux/btrfs.h>
#include <linux/namei.h>

#include "bdfs_internal.h"

/* Per-partition private state for BTRFS-backed partitions */
struct bdfs_btrfs_part_priv {
	struct mutex            subvols_lock;
	struct list_head        subvols;        /* list of bdfs_btrfs_subvol_entry */
	struct list_head        images;         /* DwarFS images stored here */
	atomic64_t              next_image_id;
	atomic64_t              next_subvol_seq;
};

struct bdfs_btrfs_subvol_entry {
	struct list_head        list;
	struct bdfs_btrfs_subvol desc;
};

struct bdfs_btrfs_image_entry {
	struct list_head        list;
	struct bdfs_dwarfs_image desc;
	/* BTRFS subvolume that contains this image file */
	u64                     container_subvol_id;
};

/* ── Backend ops ─────────────────────────────────────────────────────────── */

static int bdfs_btrfs_part_init(struct bdfs_partition_entry *entry)
{
	struct bdfs_btrfs_part_priv *priv;

	priv = kzalloc(sizeof(*priv), GFP_KERNEL);
	if (!priv)
		return -ENOMEM;

	mutex_init(&priv->subvols_lock);
	INIT_LIST_HEAD(&priv->subvols);
	INIT_LIST_HEAD(&priv->images);
	atomic64_set(&priv->next_image_id, 1);
	atomic64_set(&priv->next_subvol_seq, 1);

	entry->private = priv;
	pr_info("bdfs: BTRFS-backed partition '%s' initialised (device: %s)\n",
		entry->desc.label, entry->desc.device_path);
	return 0;
}

static void bdfs_btrfs_part_destroy(struct bdfs_partition_entry *entry)
{
	struct bdfs_btrfs_part_priv *priv = entry->private;
	struct bdfs_btrfs_subvol_entry *sv, *svtmp;
	struct bdfs_btrfs_image_entry *img, *imgtmp;

	if (!priv)
		return;

	mutex_lock(&priv->subvols_lock);
	list_for_each_entry_safe(sv, svtmp, &priv->subvols, list) {
		list_del(&sv->list);
		kfree(sv);
	}
	list_for_each_entry_safe(img, imgtmp, &priv->images, list) {
		list_del(&img->list);
		kfree(img);
	}
	mutex_unlock(&priv->subvols_lock);
	kfree(priv);
	entry->private = NULL;
}

struct bdfs_part_ops bdfs_btrfs_part_ops = {
	.name    = "btrfs_backed",
	.init    = bdfs_btrfs_part_init,
	.destroy = bdfs_btrfs_part_destroy,
};

/* ── Store DwarFS image onto BTRFS partition ────────────────────────────── */

/*
 * bdfs_btrfs_store_image - Copy a DwarFS image file into the BTRFS partition.
 *
 * The kernel side validates the source path and emits an upcall.  The daemon
 * performs the actual file copy (using sendfile or copy_file_range) and
 * optionally creates a BTRFS snapshot of the destination subvolume.
 *
 * BTRFS CoW ensures the image file is never partially written; if the copy
 * is interrupted the old version remains intact.
 */
int bdfs_btrfs_store_image(void __user *uarg,
			   struct list_head *registry,
			   struct mutex *lock)
{
	struct bdfs_ioctl_store_dwarfs_image arg;
	struct bdfs_partition_entry *entry;
	struct bdfs_btrfs_part_priv *priv;
	struct bdfs_btrfs_image_entry *img;
	char event_msg[256];

	if (copy_from_user(&arg, uarg, sizeof(arg)))
		return -EFAULT;

	mutex_lock(lock);
	entry = NULL;
	{
		struct bdfs_partition_entry *e;
		list_for_each_entry(e, registry, list) {
			if (memcmp(e->desc.uuid, arg.partition_uuid, 16) == 0) {
				entry = e;
				break;
			}
		}
	}
	mutex_unlock(lock);

	if (!entry)
		return -ENOENT;

	if (entry->desc.type != BDFS_PART_BTRFS_BACKED)
		return -EINVAL;

	priv = entry->private;

	img = kzalloc(sizeof(*img), GFP_KERNEL);
	if (!img)
		return -ENOMEM;

	img->desc.image_id = atomic64_fetch_add(1, &priv->next_image_id);
	strscpy(img->desc.name, arg.dest_name, sizeof(img->desc.name));
	snprintf(img->desc.backing_path, sizeof(img->desc.backing_path),
		 "%s/%s", entry->desc.mount_point, arg.dest_name);

	mutex_lock(&priv->subvols_lock);
	list_add_tail(&img->list, &priv->images);
	mutex_unlock(&priv->subvols_lock);

	snprintf(event_msg, sizeof(event_msg),
		 "store src=%s dest=%s flags=0x%x",
		 arg.source_path, img->desc.backing_path, arg.flags);
	bdfs_emit_event(BDFS_EVT_IMAGE_IMPORTED, arg.partition_uuid,
			img->desc.image_id, event_msg);

	if (put_user(img->desc.image_id,
		     &((struct bdfs_ioctl_store_dwarfs_image __user *)uarg)->image_id_out))
		return -EFAULT;

	pr_info("bdfs: store queued: %s → %s (image_id=%llu)\n",
		arg.source_path, img->desc.backing_path, img->desc.image_id);
	return 0;
}

/* ── Import DwarFS image → BTRFS subvolume ──────────────────────────────── */

/*
 * bdfs_btrfs_import - Extract a DwarFS image into a new BTRFS subvolume.
 *
 * The daemon runs `dwarfsextract -i <image> -o <tmpdir>` then
 * `btrfs subvolume create` + moves the extracted tree in.  The resulting
 * subvolume is optionally made read-only.
 */
int bdfs_btrfs_import(void __user *uarg,
		      struct list_head *registry,
		      struct mutex *lock)
{
	struct bdfs_ioctl_import_from_dwarfs arg;
	struct bdfs_partition_entry *entry;
	struct bdfs_btrfs_part_priv *priv;
	struct bdfs_btrfs_image_entry *img;
	struct bdfs_btrfs_subvol_entry *sv;
	char event_msg[256];
	bool found = false;

	if (copy_from_user(&arg, uarg, sizeof(arg)))
		return -EFAULT;

	mutex_lock(lock);
	entry = NULL;
	{
		struct bdfs_partition_entry *e;
		list_for_each_entry(e, registry, list) {
			if (memcmp(e->desc.uuid, arg.partition_uuid, 16) == 0) {
				entry = e;
				break;
			}
		}
	}
	mutex_unlock(lock);

	if (!entry)
		return -ENOENT;

	priv = entry->private;

	/* Locate the source image */
	mutex_lock(&priv->subvols_lock);
	list_for_each_entry(img, &priv->images, list) {
		if (img->desc.image_id == arg.image_id) {
			found = true;
			break;
		}
	}
	mutex_unlock(&priv->subvols_lock);

	if (!found)
		return -ENOENT;

	/* Pre-allocate the subvolume entry; daemon fills in the real subvol_id */
	sv = kzalloc(sizeof(*sv), GFP_KERNEL);
	if (!sv)
		return -ENOMEM;

	sv->desc.subvol_id = atomic64_fetch_add(1, &priv->next_subvol_seq);
	sv->desc.is_readonly = !!(arg.flags & BDFS_IMPORT_READONLY);
	sv->desc.is_snapshot = !!(arg.flags & BDFS_IMPORT_SNAPSHOT);
	strscpy(sv->desc.name, arg.subvol_name, sizeof(sv->desc.name));
	snprintf(sv->desc.path, sizeof(sv->desc.path),
		 "%s/%s", arg.btrfs_mount, arg.subvol_name);

	mutex_lock(&priv->subvols_lock);
	list_add_tail(&sv->list, &priv->subvols);
	mutex_unlock(&priv->subvols_lock);

	snprintf(event_msg, sizeof(event_msg),
		 "import image_id=%llu subvol=%s btrfs=%s flags=0x%x",
		 arg.image_id, arg.subvol_name, arg.btrfs_mount, arg.flags);
	bdfs_emit_event(BDFS_EVT_IMAGE_IMPORTED, arg.partition_uuid,
			arg.image_id, event_msg);

	if (put_user(sv->desc.subvol_id,
		     &((struct bdfs_ioctl_import_from_dwarfs __user *)uarg)->subvol_id_out))
		return -EFAULT;

	pr_info("bdfs: import queued: image %llu → subvol '%s'\n",
		arg.image_id, arg.subvol_name);
	return 0;
}

/* ── Snapshot the BTRFS subvolume containing a DwarFS image ─────────────── */

/*
 * bdfs_btrfs_snapshot_container - Create a BTRFS snapshot of the subvolume
 * that holds a DwarFS image file.
 *
 * This is useful for point-in-time versioning of image collections: the
 * snapshot captures the image file at its current state via BTRFS CoW,
 * so future modifications to the image (e.g. re-export) don't affect the
 * snapshot.
 */
int bdfs_btrfs_snapshot_container(void __user *uarg,
				   struct list_head *registry,
				   struct mutex *lock)
{
	struct bdfs_ioctl_snapshot_dwarfs_container arg;
	struct bdfs_partition_entry *entry;
	struct bdfs_btrfs_part_priv *priv;
	struct bdfs_btrfs_image_entry *img;
	struct bdfs_btrfs_subvol_entry *snap;
	char event_msg[256];
	bool found = false;

	if (copy_from_user(&arg, uarg, sizeof(arg)))
		return -EFAULT;

	mutex_lock(lock);
	entry = NULL;
	{
		struct bdfs_partition_entry *e;
		list_for_each_entry(e, registry, list) {
			if (memcmp(e->desc.uuid, arg.partition_uuid, 16) == 0) {
				entry = e;
				break;
			}
		}
	}
	mutex_unlock(lock);

	if (!entry)
		return -ENOENT;

	priv = entry->private;

	mutex_lock(&priv->subvols_lock);
	list_for_each_entry(img, &priv->images, list) {
		if (img->desc.image_id == arg.image_id) {
			found = true;
			break;
		}
	}
	mutex_unlock(&priv->subvols_lock);

	if (!found)
		return -ENOENT;

	snap = kzalloc(sizeof(*snap), GFP_KERNEL);
	if (!snap)
		return -ENOMEM;

	snap->desc.subvol_id = atomic64_fetch_add(1, &priv->next_subvol_seq);
	snap->desc.parent_id = img->container_subvol_id;
	snap->desc.is_snapshot = 1;
	snap->desc.is_readonly = !!(arg.flags & BDFS_SNAP_READONLY);
	strscpy(snap->desc.name, arg.snapshot_name, sizeof(snap->desc.name));

	mutex_lock(&priv->subvols_lock);
	list_add_tail(&snap->list, &priv->subvols);
	mutex_unlock(&priv->subvols_lock);

	snprintf(event_msg, sizeof(event_msg),
		 "snapshot image_id=%llu snap=%s readonly=%d",
		 arg.image_id, arg.snapshot_name, snap->desc.is_readonly);
	bdfs_emit_event(BDFS_EVT_SNAPSHOT_CREATED, arg.partition_uuid,
			snap->desc.subvol_id, event_msg);

	if (put_user(snap->desc.subvol_id,
		     &((struct bdfs_ioctl_snapshot_dwarfs_container __user *)uarg)->snapshot_subvol_id_out))
		return -EFAULT;

	pr_info("bdfs: snapshot queued: image %llu container → '%s'\n",
		arg.image_id, arg.snapshot_name);
	return 0;
}

/* ── List BTRFS subvolumes ───────────────────────────────────────────────── */

int bdfs_btrfs_list_subvols(void __user *uarg,
			    struct list_head *registry,
			    struct mutex *lock)
{
	struct bdfs_ioctl_list_btrfs_subvols arg;
	struct bdfs_partition_entry *entry;
	struct bdfs_btrfs_part_priv *priv;
	struct bdfs_btrfs_subvol_entry *sv;
	struct bdfs_btrfs_subvol __user *ubuf;
	u32 copied = 0, total = 0;

	if (copy_from_user(&arg, uarg, sizeof(arg)))
		return -EFAULT;

	mutex_lock(lock);
	entry = NULL;
	{
		struct bdfs_partition_entry *e;
		list_for_each_entry(e, registry, list) {
			if (memcmp(e->desc.uuid, arg.partition_uuid, 16) == 0) {
				entry = e;
				break;
			}
		}
	}
	mutex_unlock(lock);

	if (!entry)
		return -ENOENT;

	priv = entry->private;
	ubuf = (struct bdfs_btrfs_subvol __user *)(uintptr_t)arg.subvols;

	mutex_lock(&priv->subvols_lock);
	list_for_each_entry(sv, &priv->subvols, list) {
		total++;
		if (copied < arg.count && ubuf) {
			if (copy_to_user(&ubuf[copied], &sv->desc,
					 sizeof(sv->desc))) {
				mutex_unlock(&priv->subvols_lock);
				return -EFAULT;
			}
			copied++;
		}
	}
	mutex_unlock(&priv->subvols_lock);

	if (put_user(copied, &((struct bdfs_ioctl_list_btrfs_subvols __user *)uarg)->count))
		return -EFAULT;
	if (put_user(total, &((struct bdfs_ioctl_list_btrfs_subvols __user *)uarg)->total))
		return -EFAULT;

	return 0;
}
