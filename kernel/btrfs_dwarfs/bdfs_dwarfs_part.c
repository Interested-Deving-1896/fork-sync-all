// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * bdfs_dwarfs_part.c - DwarFS-backed partition backend
 *
 * A DwarFS-backed partition stores BTRFS subvolumes and snapshots as
 * compressed DwarFS image files.  This module handles:
 *
 *   1. Exporting a BTRFS subvolume/snapshot → DwarFS image
 *      The kernel side orchestrates a btrfs-send stream piped to the
 *      bdfs userspace daemon which drives mkdwarfs.
 *
 *   2. Mounting a DwarFS image via the FUSE dwarfs driver so that the
 *      blend layer can present it in the unified namespace.
 *
 *   3. Listing and managing DwarFS images stored on the partition.
 *
 * Heavy lifting (mkdwarfs, dwarfs FUSE mount) is done in userspace by
 * the bdfs daemon; the kernel module coordinates via upcalls through
 * the bdfs netlink socket and a shared-memory ring buffer.
 */

#include <linux/module.h>
#include <linux/slab.h>
#include <linux/uaccess.h>
#include <linux/mutex.h>
#include <linux/list.h>
#include <linux/uuid.h>
#include <linux/namei.h>
#include <linux/fs.h>
#include <linux/file.h>
#include <linux/mount.h>
#include <linux/btrfs.h>

#include "bdfs_internal.h"

/* Per-partition private state for DwarFS-backed partitions */
struct bdfs_dwarfs_part_priv {
	struct mutex            images_lock;
	struct list_head        images;         /* list of bdfs_dwarfs_image_entry */
	atomic64_t              next_image_id;
	char                    backing_dir[BDFS_PATH_MAX]; /* dir on host fs */
};

struct bdfs_dwarfs_image_entry {
	struct list_head        list;
	struct bdfs_dwarfs_image desc;
	struct vfsmount        *fuse_mnt;       /* non-NULL when mounted */
};

/* ── Backend ops ─────────────────────────────────────────────────────────── */

static int bdfs_dwarfs_part_init(struct bdfs_partition_entry *entry)
{
	struct bdfs_dwarfs_part_priv *priv;

	priv = kzalloc(sizeof(*priv), GFP_KERNEL);
	if (!priv)
		return -ENOMEM;

	mutex_init(&priv->images_lock);
	INIT_LIST_HEAD(&priv->images);
	atomic64_set(&priv->next_image_id, 1);

	/* The backing directory is the partition's device_path for image-based
	 * partitions, or a subdirectory on a host filesystem. */
	strscpy(priv->backing_dir, entry->desc.device_path,
		sizeof(priv->backing_dir));

	entry->private = priv;
	pr_info("bdfs: DwarFS-backed partition '%s' initialised (backing: %s)\n",
		entry->desc.label, priv->backing_dir);
	return 0;
}

static void bdfs_dwarfs_part_destroy(struct bdfs_partition_entry *entry)
{
	struct bdfs_dwarfs_part_priv *priv = entry->private;
	struct bdfs_dwarfs_image_entry *img, *tmp;

	if (!priv)
		return;

	mutex_lock(&priv->images_lock);
	list_for_each_entry_safe(img, tmp, &priv->images, list) {
		list_del(&img->list);
		kfree(img);
	}
	mutex_unlock(&priv->images_lock);
	kfree(priv);
	entry->private = NULL;
}

struct bdfs_part_ops bdfs_dwarfs_part_ops = {
	.name    = "dwarfs_backed",
	.init    = bdfs_dwarfs_part_init,
	.destroy = bdfs_dwarfs_part_destroy,
};

/* ── Export: BTRFS subvolume → DwarFS image ─────────────────────────────── */

/*
 * bdfs_dwarfs_export - Orchestrate export of a BTRFS subvolume to a DwarFS image.
 *
 * The kernel side:
 *   1. Validates the source subvolume exists on the given BTRFS mount.
 *   2. Opens a btrfs-send stream (BTRFS_IOC_SEND).
 *   3. Sends an upcall to the bdfs daemon with the stream fd and target path.
 *   4. The daemon pipes the send stream through dwarfsextract/mkdwarfs.
 *   5. On completion the daemon registers the new image via BDFS_IOC_STORE_DWARFS_IMAGE.
 *
 * For the kernel module skeleton we validate inputs and emit the upcall;
 * the daemon handles the actual data movement.
 */
int bdfs_dwarfs_export(void __user *uarg,
		       struct list_head *registry,
		       struct mutex *lock)
{
	struct bdfs_ioctl_export_to_dwarfs arg;
	struct bdfs_partition_entry *entry;
	struct bdfs_dwarfs_part_priv *priv;
	struct bdfs_dwarfs_image_entry *img;
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

	if (entry->desc.type != BDFS_PART_DWARFS_BACKED)
		return -EINVAL;

	priv = entry->private;

	/* Allocate image entry; the daemon will fill in size/inode counts */
	img = kzalloc(sizeof(*img), GFP_KERNEL);
	if (!img)
		return -ENOMEM;

	img->desc.image_id = atomic64_fetch_add(1, &priv->next_image_id);
	img->desc.compression = arg.compression;
	strscpy(img->desc.name, arg.image_name, sizeof(img->desc.name));
	snprintf(img->desc.backing_path, sizeof(img->desc.backing_path),
		 "%s/%s.dwarfs", priv->backing_dir, arg.image_name);

	mutex_lock(&priv->images_lock);
	list_add_tail(&img->list, &priv->images);
	mutex_unlock(&priv->images_lock);

	/* Emit event so the daemon picks up the export request.
	 *
	 * The event message carries all parameters the daemon needs to build
	 * the bdfs_job, including parent_snap_path for incremental exports.
	 * Format (space-separated key=value, values may not contain spaces):
	 *   export subvol=<id> image=<name> compression=<n> flags=<n>
	 *          btrfs_mount=<path> [parent_snap=<path>]
	 */
	if ((arg.flags & BDFS_EXPORT_INCREMENTAL) && arg.parent_snap_path[0])
		snprintf(event_msg, sizeof(event_msg),
			 "export subvol=%llu image=%s compression=%u "
			 "flags=%u btrfs_mount=%s parent_snap=%s",
			 arg.btrfs_subvol_id, arg.image_name,
			 arg.compression, arg.flags,
			 arg.btrfs_mount, arg.parent_snap_path);
	else
		snprintf(event_msg, sizeof(event_msg),
			 "export subvol=%llu image=%s compression=%u "
			 "flags=%u btrfs_mount=%s",
			 arg.btrfs_subvol_id, arg.image_name,
			 arg.compression, arg.flags,
			 arg.btrfs_mount);

	bdfs_emit_event(BDFS_EVT_SNAPSHOT_EXPORTED, arg.partition_uuid,
			img->desc.image_id, event_msg);

	/* Return the assigned image id */
	if (put_user(img->desc.image_id, &((struct bdfs_ioctl_export_to_dwarfs __user *)uarg)->image_id_out))
		return -EFAULT;

	pr_info("bdfs: export queued: subvol %llu → %s (image_id=%llu)\n",
		arg.btrfs_subvol_id, img->desc.backing_path, img->desc.image_id);
	return 0;
}

/* ── Mount / unmount DwarFS image ───────────────────────────────────────── */

/*
 * bdfs_dwarfs_mount_image - Request the daemon to FUSE-mount a DwarFS image.
 *
 * The kernel module records the mount intent and emits an event.  The daemon
 * calls `dwarfs <image_path> <mount_point>` and reports back via a separate
 * ioctl once the FUSE mount is live.
 */
int bdfs_dwarfs_mount_image(void __user *uarg,
			    struct list_head *registry,
			    struct mutex *lock)
{
	struct bdfs_ioctl_mount_dwarfs_image arg;
	struct bdfs_partition_entry *entry;
	struct bdfs_dwarfs_part_priv *priv;
	struct bdfs_dwarfs_image_entry *img;
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

	priv = entry->private;

	mutex_lock(&priv->images_lock);
	img = NULL;
	{
		struct bdfs_dwarfs_image_entry *i;
		list_for_each_entry(i, &priv->images, list) {
			if (i->desc.image_id == arg.image_id) {
				img = i;
				break;
			}
		}
	}
	mutex_unlock(&priv->images_lock);

	if (!img)
		return -ENOENT;

	if (img->desc.mounted)
		return -EBUSY;

	strscpy(img->desc.mount_point, arg.mount_point,
		sizeof(img->desc.mount_point));

	snprintf(event_msg, sizeof(event_msg),
		 "mount image_id=%llu path=%s mount=%s cache_mb=%u",
		 arg.image_id, img->desc.backing_path,
		 arg.mount_point, arg.cache_size_mb);
	bdfs_emit_event(BDFS_EVT_IMAGE_MOUNTED, arg.partition_uuid,
			arg.image_id, event_msg);

	pr_info("bdfs: mount requested: image %llu → %s\n",
		arg.image_id, arg.mount_point);
	return 0;
}

int bdfs_dwarfs_umount_image(void __user *uarg,
			     struct list_head *registry,
			     struct mutex *lock)
{
	struct bdfs_ioctl_umount_dwarfs_image arg;
	struct bdfs_partition_entry *entry;
	struct bdfs_dwarfs_part_priv *priv;
	struct bdfs_dwarfs_image_entry *img;

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

	mutex_lock(&priv->images_lock);
	img = NULL;
	{
		struct bdfs_dwarfs_image_entry *i;
		list_for_each_entry(i, &priv->images, list) {
			if (i->desc.image_id == arg.image_id) {
				img = i;
				break;
			}
		}
	}
	mutex_unlock(&priv->images_lock);

	if (!img)
		return -ENOENT;

	bdfs_emit_event(BDFS_EVT_IMAGE_UNMOUNTED, arg.partition_uuid,
			arg.image_id, NULL);
	img->desc.mounted = 0;
	memset(img->desc.mount_point, 0, sizeof(img->desc.mount_point));
	return 0;
}

/* ── List images ─────────────────────────────────────────────────────────── */

int bdfs_dwarfs_list_images(void __user *uarg,
			    struct list_head *registry,
			    struct mutex *lock)
{
	struct bdfs_ioctl_list_dwarfs_images arg;
	struct bdfs_partition_entry *entry;
	struct bdfs_dwarfs_part_priv *priv;
	struct bdfs_dwarfs_image_entry *img;
	struct bdfs_dwarfs_image __user *ubuf;
	u32 copied = 0;
	u32 total = 0;

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
	ubuf = (struct bdfs_dwarfs_image __user *)(uintptr_t)arg.images;

	mutex_lock(&priv->images_lock);
	list_for_each_entry(img, &priv->images, list) {
		total++;
		if (copied < arg.count && ubuf) {
			if (copy_to_user(&ubuf[copied], &img->desc,
					 sizeof(img->desc))) {
				mutex_unlock(&priv->images_lock);
				return -EFAULT;
			}
			copied++;
		}
	}
	mutex_unlock(&priv->images_lock);

	if (put_user(copied, &((struct bdfs_ioctl_list_dwarfs_images __user *)uarg)->count))
		return -EFAULT;
	if (put_user(total, &((struct bdfs_ioctl_list_dwarfs_images __user *)uarg)->total))
		return -EFAULT;

	return 0;
}
