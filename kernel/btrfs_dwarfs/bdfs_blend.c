// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * bdfs_blend.c - Unified namespace blend layer
 *
 * The blend layer merges a BTRFS partition and one or more DwarFS-backed
 * partitions into a single coherent filesystem namespace.  It is implemented
 * as a stackable VFS layer (similar in concept to overlayfs) with the
 * following routing rules:
 *
 *   READ path:
 *     1. Check BTRFS upper layer first (writable, live data).
 *     2. Fall through to DwarFS lower layers (read-only, compressed archives).
 *     3. If a path exists in both, the BTRFS version takes precedence.
 *
 *   WRITE path:
 *     1. All writes go to the BTRFS upper layer.
 *     2. Copy-up is performed automatically when writing to a path that
 *        currently exists only in a DwarFS lower layer (promote-on-write).
 *
 *   SNAPSHOT / ARCHIVE path:
 *     - `bdfs demote <path>` serialises a BTRFS subvolume to a DwarFS image
 *       and optionally removes the BTRFS subvolume (freeing live space).
 *     - `bdfs promote <path>` extracts a DwarFS image into a new BTRFS
 *       subvolume, making it writable.
 *
 * The blend filesystem type is registered as "bdfs_blend" and can be mounted
 * with:
 *   mount -t bdfs_blend -o btrfs=<uuid>,dwarfs=<uuid>[,<uuid>...] none <mnt>
 */

#include <linux/module.h>
#include <linux/fs.h>
#include <linux/fs_context.h>
#include <linux/slab.h>
#include <linux/uaccess.h>
#include <linux/mutex.h>
#include <linux/list.h>
#include <linux/namei.h>
#include <linux/mount.h>
#include <linux/seq_file.h>
#include <linux/statfs.h>
#include <linux/xattr.h>
#include <linux/wait.h>
#include <linux/atomic.h>
#include <linux/file.h>
#include <linux/writeback.h>
#include <linux/version.h>
#include <linux/mm.h>
#include <linux/mman.h>
#include <linux/math64.h>
#include <linux/security.h>
#include <linux/posix_acl.h>
#include <linux/posix_acl_xattr.h>

#include "bdfs_internal.h"

#define BDFS_BLEND_FS_TYPE  "bdfs_blend"
#define BDFS_BLEND_MAGIC    0xBD75B1E0

/* Layer identifiers for bdfs_ioctl_resolve_path.layer (0=btrfs, 1=dwarfs) */
#define BDFS_LAYER_UPPER    0
#define BDFS_LAYER_LOWER    1

/*
 * Whiteout marker prefix.  When a file is deleted from the blend namespace
 * we create a zero-length regular file named ".wh.<name>" on the BTRFS upper
 * layer.  During lookup, if the upper layer contains a whiteout for a name
 * that exists on a lower layer, the lower-layer entry is hidden.
 *
 * This mirrors the overlayfs / aufs convention so that existing tooling
 * (e.g. container image builders) can reason about the upper layer.
 */
#define BDFS_WH_PREFIX      ".wh."
#define BDFS_WH_PREFIX_LEN  4

/* Maximum xattr value size we handle inline (larger values use vmalloc). */
#define BDFS_XATTR_INLINE_MAX  256

/* Forward declarations for functions defined after the ops tables. */
static ssize_t bdfs_blend_copy_file_range(struct file *file_in, loff_t pos_in,
					  struct file *file_out, loff_t pos_out,
					  size_t len, unsigned int flags);
static long    bdfs_blend_ioctl(struct file *file, unsigned int cmd,
				unsigned long arg);
#ifdef CONFIG_COMPAT
static long    bdfs_blend_compat_ioctl(struct file *file, unsigned int cmd,
				       unsigned long arg);
#endif

/* Forward declarations for whiteout helpers (defined after readdir/lookup). */
static char *bdfs_blend_whiteout_name(const char *name, size_t namelen,
				      char *buf, size_t bufsz);
static bool  bdfs_blend_is_whiteout(struct dentry *dentry);
static bool  bdfs_blend_check_whiteout(struct bdfs_blend_inode_info *parent_bi,
					const char *name, size_t namelen);
static int   bdfs_blend_create_whiteout(struct inode *dir,
					const char *name, size_t namelen,
					struct bdfs_blend_mount *bm);

/*
 * SLAB_MEM_SPREAD was removed in kernel 6.15.  It was a no-op hint on most
 * architectures, so dropping it is safe.
 */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 15, 0)
# define BDFS_SLAB_FLAGS  (SLAB_RECLAIM_ACCOUNT | SLAB_ACCOUNT)
#else
# define BDFS_SLAB_FLAGS  (SLAB_RECLAIM_ACCOUNT | SLAB_MEM_SPREAD | SLAB_ACCOUNT)
#endif

/* Per-mount blend state */
struct bdfs_blend_mount {
	struct list_head        list;
	char                    mount_point[BDFS_PATH_MAX];

	/* BTRFS upper layer */
	struct vfsmount        *btrfs_mnt;
	u8                      btrfs_uuid[16];

	/* DwarFS lower layers (ordered; first = highest priority) */
	struct list_head        dwarfs_layers;
	int                     dwarfs_layer_count;

	struct bdfs_mount_opts  opts;
	struct super_block     *sb;
};

struct bdfs_dwarfs_layer {
	struct list_head        list;
	struct vfsmount        *mnt;
	u8                      partition_uuid[16];
	u64                     image_id;
	int                     priority;       /* lower = checked first */
};

static DEFINE_MUTEX(bdfs_blend_mounts_lock);
static LIST_HEAD(bdfs_blend_mounts);

/*
 * Pending copy-up table — maps (btrfs_uuid, inode_no) → blend inode.
 *
 * When bdfs_blend_trigger_copyup() emits a BDFS_EVT_COPYUP_NEEDED event it
 * registers the waiting blend inode here.  bdfs_copyup_complete() looks up
 * the inode by (uuid, ino) and calls bdfs_blend_complete_copyup() on it.
 * This avoids the incorrect ilookup(upper_sb, ino) approach which searched
 * the wrong superblock.
 */
struct bdfs_copyup_entry {
	struct list_head list;
	u8               btrfs_uuid[16];
	u64              inode_no;
	struct inode    *inode;   /* blend inode; held with ihold() */
};

static DEFINE_MUTEX(bdfs_copyup_table_lock);
static LIST_HEAD(bdfs_copyup_table);

static void bdfs_copyup_register(const u8 uuid[16], u64 ino,
				 struct inode *inode)
{
	struct bdfs_copyup_entry *e;

	e = kmalloc(sizeof(*e), GFP_KERNEL);
	if (!e)
		return;

	memcpy(e->btrfs_uuid, uuid, 16);
	e->inode_no = ino;
	e->inode    = inode;
	ihold(inode);

	mutex_lock(&bdfs_copyup_table_lock);
	list_add(&e->list, &bdfs_copyup_table);
	mutex_unlock(&bdfs_copyup_table_lock);
}

struct inode *bdfs_copyup_lookup_and_remove(const u8 uuid[16], u64 ino)
{
	struct bdfs_copyup_entry *e, *tmp;
	struct inode *found = NULL;

	mutex_lock(&bdfs_copyup_table_lock);
	list_for_each_entry_safe(e, tmp, &bdfs_copyup_table, list) {
		if (e->inode_no == ino &&
		    memcmp(e->btrfs_uuid, uuid, 16) == 0) {
			found = e->inode; /* caller owns the ihold ref */
			list_del(&e->list);
			kfree(e);
			break;
		}
	}
	mutex_unlock(&bdfs_copyup_table_lock);
	return found;
}

/* ── Superblock operations ───────────────────────────────────────────────── */

static int bdfs_blend_statfs(struct dentry *dentry, struct kstatfs *buf)
{
	/*
	 * Report aggregate stats: capacity and free space from the BTRFS upper
	 * layer (where all writes land), plus DwarFS lower-layer sizes added
	 * to f_blocks for informational purposes.
	 *
	 * f_type is overridden to BDFS_BLEND_MAGIC so statfs(2) callers can
	 * identify the blend filesystem rather than seeing BTRFS_SUPER_MAGIC.
	 */
	struct super_block *sb = dentry->d_sb;
	struct bdfs_blend_mount *bm = sb->s_fs_info;
	struct bdfs_dwarfs_layer *layer;
	struct path btrfs_root;
	struct kstatfs layer_stat;
	int ret;

	if (!bm || !bm->btrfs_mnt)
		return -EIO;

	btrfs_root.mnt    = bm->btrfs_mnt;
	btrfs_root.dentry = bm->btrfs_mnt->mnt_root;
	ret = vfs_statfs(&btrfs_root, buf);
	if (ret)
		return ret;

	buf->f_type = BDFS_BLEND_MAGIC;

	/*
	 * Add DwarFS image sizes to f_blocks (informational).  The images
	 * live on the BTRFS partition so their bytes are already counted in
	 * BTRFS used-space; we only adjust f_blocks upward so that df(1)
	 * shows a "total" that accounts for the compressed archive data.
	 * f_bfree and f_bavail are left unchanged (BTRFS figures are correct).
	 */
	list_for_each_entry(layer, &bm->dwarfs_layers, list) {
		struct path layer_root;

		if (!layer->mnt)
			continue;
		layer_root.mnt    = layer->mnt;
		layer_root.dentry = layer->mnt->mnt_root;
		if (vfs_statfs(&layer_root, &layer_stat))
			continue;
		if (buf->f_bsize > 0 && layer_stat.f_bsize > 0) {
			u64 layer_bytes = (u64)layer_stat.f_blocks *
					  layer_stat.f_bsize;
			buf->f_blocks += div64_u64(layer_bytes,
						   (u64)buf->f_bsize);
		}
	}

	return 0;
}

static void bdfs_blend_put_super(struct super_block *sb)
{
	struct bdfs_blend_mount *bm = sb->s_fs_info;
	struct bdfs_dwarfs_layer *layer, *tmp;

	if (!bm)
		return;

	list_for_each_entry_safe(layer, tmp, &bm->dwarfs_layers, list) {
		list_del(&layer->list);
		kfree(layer);
	}

	mutex_lock(&bdfs_blend_mounts_lock);
	list_del(&bm->list);
	mutex_unlock(&bdfs_blend_mounts_lock);

	kfree(bm);
	sb->s_fs_info = NULL;
}

static const struct super_operations bdfs_blend_sops = {
	.alloc_inode  = bdfs_blend_alloc_inode,
	.free_inode   = bdfs_blend_free_inode,
	.statfs       = bdfs_blend_statfs,
	.put_super    = bdfs_blend_put_super,
};

/* ── Inode operations: read routing ─────────────────────────────────────── */

/*
 * bdfs_blend_inode_from_path - Create a blend inode that aliases a real inode
 * found on a backing layer (BTRFS or DwarFS FUSE mount).
 *
 * We create a new inode in the blend superblock that mirrors the attributes
 * of the real inode.  The real path is stored in i_private so that file
 * operations can be forwarded to the backing layer.
 */
struct bdfs_blend_inode_info {
	struct inode    vfs_inode;
	struct path     real_path;      /* path on the backing layer */
	bool            is_upper;       /* true = BTRFS, false = DwarFS lower */
	atomic_t        copyup_done;    /* set to 1 when daemon finishes copy-up */
	/*
	 * Cached open file for the upper-layer backing file.
	 * Populated on first write; avoids a dentry_open() per write_iter call.
	 * Protected by the inode's i_rwsem (held by the VFS for writes).
	 * Dropped in bdfs_blend_free_inode().
	 */
	struct file    *upper_file;
};

static inline struct bdfs_blend_inode_info *
BDFS_I(struct inode *inode)
{
	return container_of(inode, struct bdfs_blend_inode_info, vfs_inode);
}

static struct inode *bdfs_blend_alloc_inode(struct super_block *sb)
{
	struct bdfs_blend_inode_info *bi;

	bi = kmem_cache_alloc(bdfs_inode_cachep, GFP_KERNEL);
	if (!bi)
		return NULL;
	memset(&bi->real_path, 0, sizeof(bi->real_path));
	bi->is_upper   = false;
	bi->upper_file = NULL;
	atomic_set(&bi->copyup_done, 0);
	return &bi->vfs_inode;
}

static void bdfs_blend_free_inode(struct inode *inode)
{
	struct bdfs_blend_inode_info *bi = BDFS_I(inode);
	if (bi->upper_file) {
		fput(bi->upper_file);
		bi->upper_file = NULL;
	}
	path_put(&bi->real_path);
	kmem_cache_free(bdfs_inode_cachep, bi);
}

/* Inode cache — allocated once at module init */
static struct kmem_cache *bdfs_inode_cachep;

static void bdfs_inode_init_once(void *obj)
{
	struct bdfs_blend_inode_info *bi = obj;
	inode_init_once(&bi->vfs_inode);
}

/*
 * bdfs_blend_make_inode - Allocate a blend inode mirroring a real inode.
 *
 * Copies uid/gid/mode/size/timestamps from the real inode so that stat(2)
 * returns correct values.  File operations are forwarded via real_path.
 */
static struct inode *bdfs_blend_make_inode(struct super_block *sb,
					   const struct path *real_path,
					   bool is_upper)
{
	struct inode *inode;
	struct inode *real = d_inode(real_path->dentry);
	struct bdfs_blend_inode_info *bi;

	inode = new_inode(sb);
	if (!inode)
		return NULL;

	bi = BDFS_I(inode);
	path_get(real_path);
	bi->real_path = *real_path;
	bi->is_upper  = is_upper;
	atomic_set(&bi->copyup_done, is_upper ? 1 : 0);

	/* Mirror attributes from the real inode */
	inode->i_ino   = real->i_ino;
	inode->i_mode  = real->i_mode;
	inode->i_uid   = real->i_uid;
	inode->i_gid   = real->i_gid;
	inode->i_size  = real->i_size;
	inode_set_atime_to_ts(inode, inode_get_atime(real));
	inode_set_mtime_to_ts(inode, inode_get_mtime(real));
	inode_set_ctime_to_ts(inode, inode_get_ctime(real));
	set_nlink(inode, real->i_nlink);

	if (S_ISDIR(inode->i_mode)) {
		inode->i_op  = &bdfs_blend_dir_iops;
		inode->i_fop = &bdfs_blend_dir_fops;
	} else if (S_ISREG(inode->i_mode)) {
		inode->i_op  = &bdfs_blend_file_iops;
		inode->i_fop = &bdfs_blend_file_fops;
	} else if (S_ISLNK(inode->i_mode)) {
		inode->i_op  = &bdfs_blend_symlink_iops;
		/* symlinks have no file_operations */
	} else {
		/* Special files (devices, fifos, sockets): forward to real */
		init_special_inode(inode, inode->i_mode, real->i_rdev);
	}

	return inode;
}

/*
 * bdfs_blend_rel_path - Build the path of @dentry relative to the blend root.
 *
 * Walks the dentry parent chain up to the blend superblock root, collecting
 * component names, then assembles them into a slash-separated string in @buf.
 * Returns a pointer into @buf on success, or ERR_PTR on error.
 *
 * Example: for blend root "/" and dentry at "a/b/c", returns "a/b/c".
 */
static char *bdfs_blend_rel_path(struct dentry *dentry, char *buf, size_t bufsz)
{
	/* Walk up to the root collecting names */
	struct dentry *d = dentry;
	char *p = buf + bufsz - 1;
	*p = '\0';

	while (!IS_ROOT(d)) {
		const char *name = d->d_name.name;
		size_t len = d->d_name.len;

		if (p - buf < (ptrdiff_t)(len + 1))
			return ERR_PTR(-ENAMETOOLONG);

		p -= len;
		memcpy(p, name, len);
		p--;
		*p = '/';
		d = d->d_parent;
	}

	/* p now points at the leading '/' — skip it */
	if (*p == '/')
		p++;

	return p;
}

/*
 * bdfs_blend_lookup - Resolve a name in the blend namespace.
 *
 * Routing order:
 *   1. BTRFS upper layer  (writable; takes precedence on name collision)
 *   2. DwarFS lower layers in priority order (read-only compressed archives)
 *
 * For each layer we use vfs_path_lookup() to resolve the FULL relative path
 * from the layer root to the child being looked up.  This correctly handles
 * nested directories: "a/b/c" is resolved as a single lookup from the layer
 * root rather than just resolving "c" relative to the layer root (which would
 * only work for top-level entries).
 *
 * Copy-up on write is handled at the file_operations level: any write to a
 * blend inode backed by a DwarFS lower layer triggers a copy-up to the BTRFS
 * upper layer before the write proceeds.
 */
static struct dentry *bdfs_blend_lookup(struct inode *dir,
					struct dentry *dentry,
					unsigned int flags)
{
	struct super_block *sb = dir->i_sb;
	struct bdfs_blend_mount *bm = sb->s_fs_info;
	struct bdfs_blend_inode_info *parent_bi = BDFS_I(dir);
	struct path parent_real = parent_bi->real_path;
	struct path child_path;
	struct inode *new_inode;
	struct dentry *new_dentry;
	const char *name = dentry->d_name.name;
	/* Full relative path buffer — used for lower-layer lookups */
	char *relpath_buf;
	char *relpath;
	int err;

	/*
	 * Build the full relative path for this dentry (e.g. "usr/lib/foo.so").
	 * We need this for lower-layer lookups so that nested directories are
	 * resolved correctly from the layer root rather than just by name.
	 */
	relpath_buf = kmalloc(PATH_MAX, GFP_KERNEL);
	if (!relpath_buf)
		return ERR_PTR(-ENOMEM);

	relpath = bdfs_blend_rel_path(dentry, relpath_buf, PATH_MAX);
	if (IS_ERR(relpath)) {
		kfree(relpath_buf);
		return ERR_CAST(relpath);
	}

	/*
	 * Step 1: Try the BTRFS upper layer.
	 *
	 * If the parent is already on the upper layer, resolve relative to it
	 * (single component lookup — fast path).  If the parent is from a
	 * lower layer, resolve the full relative path from the BTRFS root so
	 * we find any upper-layer override at any depth.
	 */
	if (bm->btrfs_mnt) {
		if (parent_bi->is_upper) {
			/* Fast path: parent is already on upper layer */
			err = vfs_path_lookup(parent_real.dentry,
					      parent_real.mnt,
					      name, 0, &child_path);
		} else {
			/* Full path from BTRFS root */
			err = vfs_path_lookup(bm->btrfs_mnt->mnt_root,
					      bm->btrfs_mnt,
					      relpath, 0, &child_path);
		}
		if (!err && d_is_positive(child_path.dentry)) {
			new_inode = bdfs_blend_make_inode(sb, &child_path,
							  true);
			path_put(&child_path);
			kfree(relpath_buf);
			if (!new_inode)
				return ERR_PTR(-ENOMEM);
			new_dentry = d_splice_alias(new_inode, dentry);
			return new_dentry ? new_dentry : dentry;
		}
		if (!err)
			path_put(&child_path);
	}

	/*
	 * Step 2: Check for a whiteout on the upper layer before falling
	 * through to lower layers.  A whiteout (".wh.<name>") means the
	 * entry was explicitly deleted from the blend namespace; we must
	 * hide any lower-layer entry with the same name.
	 *
	 * We only check when the upper layer is available and the parent
	 * directory is on the upper layer (if the parent is lower-only,
	 * no whiteout can exist for this name yet).
	 */
	if (bm->btrfs_mnt && parent_bi->is_upper &&
	    bdfs_blend_check_whiteout(parent_bi, name, strlen(name))) {
		kfree(relpath_buf);
		d_add(dentry, NULL);
		return NULL;
	}

	/*
	 * Step 3: Fall through to DwarFS lower layers in priority order.
	 *
	 * Resolve the full relative path from each layer's root so that
	 * nested directories (e.g. "usr/lib/foo.so") are found correctly
	 * regardless of how deep the current directory is.
	 */
	{
		struct bdfs_dwarfs_layer *layer;

		list_for_each_entry(layer, &bm->dwarfs_layers, list) {
			if (!layer->mnt)
				continue;

			err = vfs_path_lookup(layer->mnt->mnt_root,
					      layer->mnt, relpath, 0,
					      &child_path);
			if (!err && d_is_positive(child_path.dentry)) {
				new_inode = bdfs_blend_make_inode(
						sb, &child_path, false);
				path_put(&child_path);
				kfree(relpath_buf);
				if (!new_inode)
					return ERR_PTR(-ENOMEM);
				new_dentry = d_splice_alias(new_inode, dentry);
				return new_dentry ? new_dentry : dentry;
			}
			if (!err)
				path_put(&child_path);
		}
	}

	/* Not found in any layer — return a negative dentry */
	kfree(relpath_buf);
	d_add(dentry, NULL);
	return NULL;
}

/*
 * bdfs_blend_getattr - Forward stat to the real backing inode.
 *
 * Refreshes size and timestamps from the real inode before returning,
 * so that changes on the backing layer are reflected immediately.
 */
static int bdfs_blend_getattr(struct mnt_idmap *idmap,
			      const struct path *path,
			      struct kstat *stat,
			      u32 request_mask,
			      unsigned int query_flags)
{
	struct inode *inode = d_inode(path->dentry);
	struct bdfs_blend_inode_info *bi = BDFS_I(inode);
	struct inode *real;

	if (!bi->real_path.dentry)
		return -EIO;

	real = d_inode(bi->real_path.dentry);

	/* Refresh from real inode */
	inode->i_size  = real->i_size;
	inode_set_atime_to_ts(inode, inode_get_atime(real));
	inode_set_mtime_to_ts(inode, inode_get_mtime(real));
	inode_set_ctime_to_ts(inode, inode_get_ctime(real));

	generic_fillattr(idmap, request_mask, inode, stat);
	return 0;
}

/* ── Copy-up synchronization ─────────────────────────────────────────────── */

/*
 * Per-inode copy-up state.  When a write is attempted on a DwarFS-backed
 * inode the kernel emits a BDFS_EVT_COPYUP_NEEDED event and then waits on
 * copyup_done.  The daemon performs the promote job and calls back via
 * BDFS_IOC_COPYUP_COMPLETE (handled in bdfs_main.c), which wakes all
 * waiters and flips copyup_done to 1.
 *
 * Once copy-up completes, real_path is updated to point at the new BTRFS
 * upper-layer file and is_upper is set to true.  Subsequent opens skip
 * the copy-up path entirely.
 */
static DECLARE_WAIT_QUEUE_HEAD(bdfs_copyup_wq);

/*
 * bdfs_blend_trigger_copyup - Emit copy-up event and wait for completion.
 *
 * Returns 0 when the daemon has finished promoting the file to the BTRFS
 * upper layer, or a negative error code on timeout / signal.
 *
 * The caller must hold no locks.  We use an interruptible wait with a
 * 30-second timeout so a crashed daemon does not wedge the process forever.
 */
static int bdfs_blend_trigger_copyup(struct inode *inode,
				     struct bdfs_blend_mount *bm)
{
	struct bdfs_blend_inode_info *bi = BDFS_I(inode);
	long timeout;

	/* Register in the copyup table so bdfs_copyup_complete can find us */
	bdfs_copyup_register(bm->btrfs_uuid, inode->i_ino, inode);

	/*
	 * Emit the event.  The daemon listens on the netlink socket and will
	 * start a BDFS_JOB_PROMOTE_COPYUP for this inode.
	 *
	 * Message format:
	 *   "copyup_needed lower=<lower_path> upper=<upper_path>"
	 *
	 * lower_path: the absolute path of the file on the DwarFS FUSE mount.
	 * upper_path: the corresponding absolute path on the BTRFS upper layer.
	 *
	 * The upper path is derived by:
	 *   1. Resolving the absolute path of the BTRFS upper mount root via
	 *      d_path().
	 *   2. Building the relative path from the DwarFS layer root to this
	 *      inode via bdfs_blend_rel_path() — this gives the full nested
	 *      path (e.g. "usr/lib/foo.so"), not just the basename.
	 *   3. Concatenating: upper = btrfs_root_abs + "/" + rel_path.
	 *
	 * Using only the basename (strrchr) was wrong for nested paths: a file
	 * at "usr/lib/foo.so" would have been placed at the BTRFS root as
	 * "foo.so" instead of "usr/lib/foo.so".
	 */
	{
		char lower_buf[256] = {0};
		char upper_buf[256] = {0};
		char msg[sizeof(((struct bdfs_event *)0)->message)];

		/* Resolve the absolute lower path on the DwarFS FUSE mount */
		if (bi->real_path.dentry && bi->real_path.mnt) {
			char *p = d_path(&bi->real_path, lower_buf,
					 sizeof(lower_buf));
			if (!IS_ERR(p))
				memmove(lower_buf, p, strlen(p) + 1);
		}

		/*
		 * Derive the upper path using the full relative path from the
		 * blend root to this inode, not just the final name component.
		 */
		if (bm->btrfs_mnt) {
			struct path btrfs_root = {
				.mnt    = bm->btrfs_mnt,
				.dentry = bm->btrfs_mnt->mnt_root,
			};
			char root_buf[256] = {0};
			char *rp = d_path(&btrfs_root, root_buf,
					  sizeof(root_buf));
			if (!IS_ERR(rp)) {
				char *relpath_buf = kmalloc(PATH_MAX,
							    GFP_KERNEL);
				if (relpath_buf) {
					char *rel = bdfs_blend_rel_path(
						bi->real_path.dentry,
						relpath_buf, PATH_MAX);
					if (!IS_ERR(rel))
						snprintf(upper_buf,
							 sizeof(upper_buf),
							 "%s/%s", rp, rel);
					kfree(relpath_buf);
				}
			}
		}

		snprintf(msg, sizeof(msg),
			 "copyup_needed lower=%s upper=%s",
			 lower_buf, upper_buf);

		bdfs_emit_event(BDFS_EVT_COPYUP_NEEDED,
				bm->btrfs_uuid, inode->i_ino, msg);
	}

	/*
	 * Wait for the daemon to signal completion.  The daemon calls
	 * BDFS_IOC_COPYUP_COMPLETE which sets bi->copyup_done and wakes us.
	 */
	timeout = wait_event_interruptible_timeout(
		bdfs_copyup_wq,
		atomic_read(&bi->copyup_done) != 0,
		30 * HZ);

	if (timeout < 0)
		return -EINTR;
	if (timeout == 0)
		return -ETIMEDOUT;

	return 0;
}

/* ── File operations ─────────────────────────────────────────────────────── */

/*
 * bdfs_blend_open - Forward open to the real backing file.
 *
 * For write-mode opens on a DwarFS-backed inode, copy-up is triggered:
 * we emit a promote event to the daemon and block until it completes.
 * Once copy-up is done, real_path points to the BTRFS upper layer and
 * subsequent opens take the fast path.
 */
static int bdfs_blend_open(struct inode *inode, struct file *file)
{
	struct bdfs_blend_inode_info *bi = BDFS_I(inode);
	struct super_block *sb = inode->i_sb;
	struct bdfs_blend_mount *bm = sb->s_fs_info;
	int ret;

	if (!bi->is_upper && (file->f_flags & (O_WRONLY | O_RDWR))) {
		ret = bdfs_blend_trigger_copyup(inode, bm);
		if (ret)
			return ret;
		/*
		 * After copy-up, bi->real_path and bi->is_upper have been
		 * updated by bdfs_blend_complete_copyup() called from the
		 * BDFS_IOC_COPYUP_COMPLETE ioctl handler.
		 */
	}

	return finish_open(file, bi->real_path.dentry, generic_file_open);
}

/* ── Directory write operations ──────────────────────────────────────────── */

/*
 * bdfs_blend_create - Create a new regular file on the BTRFS upper layer.
 *
 * New files are always created on the upper layer regardless of whether a
 * lower-layer directory exists at the same path.
 */
static int bdfs_blend_create(struct mnt_idmap *idmap,
			     struct inode *dir, struct dentry *dentry,
			     umode_t mode, bool excl)
{
	struct super_block *sb = dir->i_sb;
	struct bdfs_blend_mount *bm = sb->s_fs_info;
	struct bdfs_blend_inode_info *parent_bi = BDFS_I(dir);
	struct path upper_parent;
	struct dentry *upper_dentry;
	struct inode *new_inode;
	int ret;

	if (!bm || !bm->btrfs_mnt)
		return -EIO;

	/*
	 * Resolve the parent directory on the BTRFS upper layer.
	 *
	 * When the parent blend inode is already on the upper layer we can
	 * use its cached real_path directly.  When it is a lower-layer inode
	 * we must look up the full relative path from the BTRFS root so that
	 * nested directories (e.g. "a/b/c") are resolved correctly — using
	 * an empty path would land at the BTRFS root instead of the right
	 * subdirectory.
	 */
	if (parent_bi->is_upper) {
		path_get(&parent_bi->real_path);
		upper_parent = parent_bi->real_path;
	} else {
		char *relpath_buf = kmalloc(PATH_MAX, GFP_KERNEL);
		char *relpath;

		if (!relpath_buf)
			return -ENOMEM;

		relpath = bdfs_blend_rel_path(parent_bi->real_path.dentry,
					      relpath_buf, PATH_MAX);
		if (IS_ERR(relpath)) {
			kfree(relpath_buf);
			return PTR_ERR(relpath);
		}

		ret = vfs_path_lookup(bm->btrfs_mnt->mnt_root,
				      bm->btrfs_mnt, relpath, 0, &upper_parent);
		kfree(relpath_buf);
		if (ret)
			return ret;
	}

	upper_dentry = lookup_one(idmap, &dentry->d_name, upper_parent.dentry);
	if (IS_ERR(upper_dentry)) {
		path_put(&upper_parent);
		return PTR_ERR(upper_dentry);
	}

	ret = vfs_create(idmap, d_inode(upper_parent.dentry),
			 upper_dentry, mode, excl);
	if (ret) {
		dput(upper_dentry);
		path_put(&upper_parent);
		return ret;
	}

	/* Wrap the new upper-layer inode in a blend inode */
	struct path new_path = { .mnt = upper_parent.mnt,
				 .dentry = upper_dentry };
	new_inode = bdfs_blend_make_inode(sb, &new_path, true);
	dput(upper_dentry);
	path_put(&upper_parent);

	if (!new_inode)
		return -ENOMEM;

	d_instantiate(dentry, new_inode);
	return 0;
}

/*
 * bdfs_blend_mkdir - Create a directory on the BTRFS upper layer.
 *
 * In kernel 6.17+, .mkdir returns struct dentry * (like .lookup/.create).
 * vfs_mkdir() also returns struct dentry * on success, ERR_PTR on error.
 */
static struct dentry *bdfs_blend_mkdir(struct mnt_idmap *idmap,
				       struct inode *dir, struct dentry *dentry,
				       umode_t mode)
{
	struct super_block *sb = dir->i_sb;
	struct bdfs_blend_mount *bm = sb->s_fs_info;
	struct bdfs_blend_inode_info *parent_bi = BDFS_I(dir);
	struct path upper_parent;
	struct dentry *upper_dentry;
	struct dentry *real_dentry;
	struct inode *new_inode;
	int ret;

	if (!bm || !bm->btrfs_mnt)
		return ERR_PTR(-EIO);

	/* See bdfs_blend_create for the rationale behind the lower-layer path. */
	if (parent_bi->is_upper) {
		path_get(&parent_bi->real_path);
		upper_parent = parent_bi->real_path;
	} else {
		char *relpath_buf = kmalloc(PATH_MAX, GFP_KERNEL);
		char *relpath;

		if (!relpath_buf)
			return ERR_PTR(-ENOMEM);

		relpath = bdfs_blend_rel_path(parent_bi->real_path.dentry,
					      relpath_buf, PATH_MAX);
		if (IS_ERR(relpath)) {
			kfree(relpath_buf);
			return ERR_CAST(relpath);
		}

		ret = vfs_path_lookup(bm->btrfs_mnt->mnt_root,
				      bm->btrfs_mnt, relpath, 0, &upper_parent);
		kfree(relpath_buf);
		if (ret)
			return ERR_PTR(ret);
	}

	upper_dentry = lookup_one(idmap, &dentry->d_name, upper_parent.dentry);
	if (IS_ERR(upper_dentry)) {
		path_put(&upper_parent);
		return upper_dentry;
	}

	/* vfs_mkdir returns the new dentry (or ERR_PTR) in 6.17+ */
	real_dentry = vfs_mkdir(idmap, d_inode(upper_parent.dentry),
				upper_dentry, mode);
	dput(upper_dentry);
	if (IS_ERR(real_dentry)) {
		path_put(&upper_parent);
		return real_dentry;
	}

	struct path new_path = { .mnt = upper_parent.mnt,
				 .dentry = real_dentry };
	new_inode = bdfs_blend_make_inode(sb, &new_path, true);
	dput(real_dentry);
	path_put(&upper_parent);

	if (!new_inode)
		return ERR_PTR(-ENOMEM);

	return d_splice_alias(new_inode, dentry);
}

/*
 * bdfs_blend_unlink - Remove a file from the BTRFS upper layer.
 *
 * Removing a file that exists only in a DwarFS lower layer is not permitted
 * without a prior promote (copy-up).  The blend layer is not a full
 * union filesystem — whiteouts are not implemented.
 */
static int bdfs_blend_unlink(struct inode *dir, struct dentry *dentry)
{
	struct bdfs_blend_inode_info *bi = BDFS_I(d_inode(dentry));
	struct bdfs_blend_inode_info *parent_bi = BDFS_I(dir);
	struct super_block *sb = dir->i_sb;
	struct bdfs_blend_mount *bm = sb->s_fs_info;
	struct mnt_idmap *idmap;
	int ret;

	if (bi->is_upper) {
		/*
		 * Upper-layer file: delete it directly.  If a lower-layer
		 * entry with the same name exists, also create a whiteout so
		 * the lower entry stays hidden after the upper one is gone.
		 */
		idmap = mnt_idmap(bi->real_path.mnt);
		ret = vfs_unlink(idmap,
				 d_inode(parent_bi->real_path.dentry),
				 bi->real_path.dentry,
				 NULL);
		if (ret)
			return ret;

		/*
		 * Create a whiteout if a lower-layer entry exists with this
		 * name.  Failure is non-fatal: the upper entry is already
		 * gone; the whiteout just prevents the lower entry from
		 * reappearing.  Log a warning so the operator is aware.
		 */
		{
			const char *name = dentry->d_name.name;
			size_t namelen = dentry->d_name.len;
			struct bdfs_dwarfs_layer *layer;
			bool lower_exists = false;
			char *rbuf = kmalloc(PATH_MAX, GFP_KERNEL);

			if (rbuf) {
				char *rp = bdfs_blend_rel_path(dentry, rbuf,
							       PATH_MAX);
				if (!IS_ERR(rp)) {
					list_for_each_entry(layer,
							    &bm->dwarfs_layers,
							    list) {
						struct path lp;

						if (!layer->mnt)
							continue;
						if (!vfs_path_lookup(
							layer->mnt->mnt_root,
							layer->mnt, rp, 0,
							&lp)) {
							lower_exists =
							  d_is_positive(lp.dentry);
							path_put(&lp);
							if (lower_exists)
								break;
						}
					}
				}
				kfree(rbuf);
			}

			if (lower_exists) {
				int wret = bdfs_blend_create_whiteout(
						dir, name, namelen, bm);
				if (wret)
					pr_warn("bdfs: whiteout for '%s' failed: %d\n",
						name, wret);
			}
		}
		return 0;
	}

	/*
	 * Lower-layer file: we cannot delete it (DwarFS is read-only).
	 * Create a whiteout on the upper layer so the entry is hidden.
	 * This is the overlayfs model: deletion of a lower-layer entry
	 * is represented by a ".wh.<name>" marker on the upper layer.
	 */
	return bdfs_blend_create_whiteout(dir,
					  dentry->d_name.name,
					  dentry->d_name.len,
					  bm);
}

/*
 * bdfs_blend_rmdir - Remove a directory from the blend namespace.
 *
 * Upper-layer directories are removed directly via vfs_rmdir.
 * Lower-layer directories (DwarFS, read-only) are hidden by creating a
 * whiteout on the upper layer, consistent with bdfs_blend_unlink.
 */
static int bdfs_blend_rmdir(struct inode *dir, struct dentry *dentry)
{
	struct bdfs_blend_inode_info *bi = BDFS_I(d_inode(dentry));
	struct bdfs_blend_inode_info *parent_bi = BDFS_I(dir);
	struct super_block *sb = dir->i_sb;
	struct bdfs_blend_mount *bm = sb->s_fs_info;
	struct mnt_idmap *idmap;

	if (bi->is_upper) {
		idmap = mnt_idmap(bi->real_path.mnt);
		return vfs_rmdir(idmap,
				 d_inode(parent_bi->real_path.dentry),
				 bi->real_path.dentry);
	}

	/* Lower-layer directory: create a whiteout to hide it. */
	return bdfs_blend_create_whiteout(dir,
					  dentry->d_name.name,
					  dentry->d_name.len,
					  bm);
}

/*
 * bdfs_blend_rename - Rename within the BTRFS upper layer.
 *
 * Both source and destination must be on the upper layer.  Renaming a
 * lower-layer entry requires a prior promote.
 */
static int bdfs_blend_rename(struct mnt_idmap *idmap,
			     struct inode *old_dir, struct dentry *old_dentry,
			     struct inode *new_dir, struct dentry *new_dentry,
			     unsigned int flags)
{
	struct bdfs_blend_inode_info *src_bi      = BDFS_I(d_inode(old_dentry));
	struct bdfs_blend_inode_info *old_par_bi  = BDFS_I(old_dir);
	struct bdfs_blend_inode_info *new_par_bi  = BDFS_I(new_dir);
	struct dentry *real_new_dentry;
	int ret;

	if (!src_bi->is_upper)
		return -EPERM;

	if (!old_par_bi->is_upper || !new_par_bi->is_upper)
		return -EPERM;

	/*
	 * new_dentry is a blend-layer dentry.  We must look up the
	 * corresponding dentry in the BTRFS upper layer so vfs_rename
	 * operates entirely within one real filesystem.
	 */
	real_new_dentry = lookup_one(idmap, &new_dentry->d_name,
				     new_par_bi->real_path.dentry);
	if (IS_ERR(real_new_dentry))
		return PTR_ERR(real_new_dentry);

	ret = vfs_rename(&(struct renamedata){
			.old_mnt_idmap = idmap,
			.old_parent    = old_par_bi->real_path.dentry,
			.old_dentry    = src_bi->real_path.dentry,
			.new_mnt_idmap = idmap,
			.new_parent    = new_par_bi->real_path.dentry,
			.new_dentry    = real_new_dentry,
			.flags         = flags,
		});

	dput(real_new_dentry);
	return ret;
}

/*
 * bdfs_blend_symlink - Create a symbolic link on the BTRFS upper layer.
 */
static int bdfs_blend_symlink(struct mnt_idmap *idmap,
			      struct inode *dir, struct dentry *dentry,
			      const char *symname)
{
	struct super_block *sb = dir->i_sb;
	struct bdfs_blend_mount *bm = sb->s_fs_info;
	struct bdfs_blend_inode_info *parent_bi = BDFS_I(dir);
	struct path upper_parent;
	struct dentry *upper_dentry;
	struct inode *new_inode;
	int ret;

	if (!bm || !bm->btrfs_mnt)
		return -EIO;

	/* See bdfs_blend_create for the rationale behind the lower-layer path. */
	if (parent_bi->is_upper) {
		path_get(&parent_bi->real_path);
		upper_parent = parent_bi->real_path;
	} else {
		char *relpath_buf = kmalloc(PATH_MAX, GFP_KERNEL);
		char *relpath;

		if (!relpath_buf)
			return -ENOMEM;

		relpath = bdfs_blend_rel_path(parent_bi->real_path.dentry,
					      relpath_buf, PATH_MAX);
		if (IS_ERR(relpath)) {
			kfree(relpath_buf);
			return PTR_ERR(relpath);
		}

		ret = vfs_path_lookup(bm->btrfs_mnt->mnt_root,
				      bm->btrfs_mnt, relpath, 0, &upper_parent);
		kfree(relpath_buf);
		if (ret)
			return ret;
	}

	upper_dentry = lookup_one(idmap, &dentry->d_name, upper_parent.dentry);
	if (IS_ERR(upper_dentry)) {
		path_put(&upper_parent);
		return PTR_ERR(upper_dentry);
	}

	ret = vfs_symlink(idmap, d_inode(upper_parent.dentry),
			  upper_dentry, symname);
	if (ret) {
		dput(upper_dentry);
		path_put(&upper_parent);
		return ret;
	}

	struct path new_path = { .mnt = upper_parent.mnt,
				 .dentry = upper_dentry };
	new_inode = bdfs_blend_make_inode(sb, &new_path, true);
	dput(upper_dentry);
	path_put(&upper_parent);

	if (!new_inode)
		return -ENOMEM;

	d_instantiate(dentry, new_inode);
	return 0;
}

/*
 * bdfs_blend_link - Create a hard link on the BTRFS upper layer.
 *
 * Both the source inode and the target directory must be on the upper layer.
 * Linking a lower-layer inode requires a prior promote.
 */
static int bdfs_blend_link(struct dentry *old_dentry, struct inode *dir,
			   struct dentry *new_dentry)
{
	struct bdfs_blend_inode_info *src_bi    = BDFS_I(d_inode(old_dentry));
	struct bdfs_blend_inode_info *parent_bi = BDFS_I(dir);
	struct dentry *real_new_dentry;
	struct mnt_idmap *idmap;
	int ret;

	if (!src_bi->is_upper || !parent_bi->is_upper)
		return -EPERM;

	idmap = mnt_idmap(src_bi->real_path.mnt);
	real_new_dentry = lookup_one(idmap, &new_dentry->d_name,
				     parent_bi->real_path.dentry);
	if (IS_ERR(real_new_dentry))
		return PTR_ERR(real_new_dentry);
	ret = vfs_link(src_bi->real_path.dentry, idmap,
		       d_inode(parent_bi->real_path.dentry),
		       real_new_dentry, NULL);
	dput(real_new_dentry);
	return ret;
}

/*
 * bdfs_blend_setattr - Forward attribute changes to the BTRFS upper layer.
 *
 * chmod/chown/truncate on a lower-layer inode requires copy-up first.
 */
static int bdfs_blend_setattr(struct mnt_idmap *idmap,
			      struct dentry *dentry, struct iattr *attr)
{
	struct inode *inode = d_inode(dentry);
	struct bdfs_blend_inode_info *bi = BDFS_I(inode);
	struct super_block *sb = inode->i_sb;
	struct bdfs_blend_mount *bm = sb->s_fs_info;
	int ret;

	if (!bi->is_upper) {
		ret = bdfs_blend_trigger_copyup(inode, bm);
		if (ret)
			return ret;
	}

	ret = setattr_prepare(idmap, dentry, attr);
	if (ret)
		return ret;

	ret = notify_change(idmap, bi->real_path.dentry, attr, NULL);
	if (ret)
		return ret;

	setattr_copy(idmap, inode, attr);
	mark_inode_dirty(inode);
	return 0;
}

/*
 * bdfs_blend_complete_copyup - Called from BDFS_IOC_COPYUP_COMPLETE ioctl.
 *
 * Updates the inode's real_path to point at the new BTRFS upper-layer file,
 * marks it as upper, and wakes all threads waiting in bdfs_blend_open().
 *
 * @inode:      the blend inode being promoted
 * @upper_path: the new path on the BTRFS upper layer
 */
void bdfs_blend_complete_copyup(struct inode *inode,
				const struct path *upper_path)
{
	struct bdfs_blend_inode_info *bi = BDFS_I(inode);

	path_put(&bi->real_path);
	path_get(upper_path);
	bi->real_path = *upper_path;
	bi->is_upper  = true;

	atomic_set(&bi->copyup_done, 1);
	wake_up_all(&bdfs_copyup_wq);
}
EXPORT_SYMBOL_GPL(bdfs_blend_complete_copyup);

/* ── Xattr forwarding ────────────────────────────────────────────────────── */

/*
 * Forward xattr operations to the real backing inode.
 * For upper-layer inodes this reaches BTRFS; for lower-layer inodes it
 * reaches the DwarFS FUSE handler (which may return -ENOTSUP for setxattr).
 */
static ssize_t bdfs_blend_listxattr(struct dentry *dentry, char *list,
				    size_t size)
{
	struct inode *inode = d_inode(dentry);
	struct bdfs_blend_inode_info *bi = BDFS_I(inode);

	if (!bi->real_path.dentry)
		return -EIO;

	return vfs_listxattr(bi->real_path.dentry, list, size);
}

/* ── Symlink forwarding ──────────────────────────────────────────────────── */

/*
 * bdfs_blend_get_link - Return the symlink target from the backing layer.
 *
 * We delegate to the real inode's get_link so that path resolution through
 * symlinks in the blend namespace works correctly.
 */
static const char *bdfs_blend_get_link(struct dentry *dentry,
				       struct inode *inode,
				       struct delayed_call *done)
{
	struct bdfs_blend_inode_info *bi = BDFS_I(inode);
	struct inode *real;

	if (!dentry)
		return ERR_PTR(-ECHILD); /* RCU lookup not supported */

	if (!bi->real_path.dentry)
		return ERR_PTR(-EIO);

	real = d_inode(bi->real_path.dentry);
	if (!real->i_op || !real->i_op->get_link)
		return ERR_PTR(-EINVAL);

	return real->i_op->get_link(bi->real_path.dentry, real, done);
}

/* ── Directory readdir ───────────────────────────────────────────────────── */

/*
 * bdfs_blend_iterate_shared - Enumerate directory entries from both layers.
 *
 * We iterate the BTRFS upper layer first, then each DwarFS lower layer.
 * Entries that already appeared in the upper layer are deduplicated by
 * tracking emitted names in a small hash set.  For simplicity we use a
 * fixed-size bitmap over a hash of the name; false positives (suppressing
 * a lower-layer entry that happens to hash-collide with an upper entry) are
 * acceptable — the entry is still accessible via lookup.
 *
 * The real directory is opened via dentry_open() and iterated with
 * iterate_dir(), which calls the backing filesystem's iterate_shared.
 */

#define BDFS_DEDUP_BITS  512   /* power of two; covers ~360 entries at 50% */
#define BDFS_DEDUP_MASK  (BDFS_DEDUP_BITS - 1)

struct bdfs_readdir_ctx {
	struct dir_context  ctx;
	struct dir_context *caller_ctx;
	unsigned long       seen[BDFS_DEDUP_BITS / BITS_PER_LONG];
	bool                dedup; /* true = skip names already in seen[] */
};

static bool bdfs_dedup_test_set(struct bdfs_readdir_ctx *rc,
				const char *name, int namlen)
{
	unsigned long h = full_name_hash(NULL, name, namlen) & BDFS_DEDUP_MASK;
	bool already = test_bit(h, rc->seen);
	set_bit(h, rc->seen);
	return already;
}

static bool bdfs_filldir(struct dir_context *ctx, const char *name, int namlen,
			 loff_t offset, u64 ino, unsigned int d_type)
{
	struct bdfs_readdir_ctx *rc =
		container_of(ctx, struct bdfs_readdir_ctx, ctx);

	/*
	 * Never expose whiteout marker files (".wh.<name>") to userspace.
	 * They are an internal implementation detail of the blend layer.
	 */
	if (namlen > BDFS_WH_PREFIX_LEN &&
	    memcmp(name, BDFS_WH_PREFIX, BDFS_WH_PREFIX_LEN) == 0)
		return true; /* skip; continue iteration */

	if (rc->dedup) {
		/*
		 * Lower-layer pass: skip entries already seen in the upper
		 * layer (dedup) and entries that have a whiteout in the upper
		 * layer (the whiteout name ".wh.<name>" was recorded in seen[]
		 * during the upper pass via bdfs_dedup_test_set).
		 *
		 * We synthesise the whiteout name and check the dedup bitmap.
		 * This is a probabilistic check (hash collision possible) but
		 * false positives only suppress lower entries that happen to
		 * collide — they remain accessible via lookup.
		 */
		char wh_buf[NAME_MAX + BDFS_WH_PREFIX_LEN + 1];
		char *wh_name = bdfs_blend_whiteout_name(name, namlen,
							  wh_buf,
							  sizeof(wh_buf));
		if (!IS_ERR(wh_name)) {
			unsigned long wh_h = full_name_hash(NULL, wh_name,
						strlen(wh_name)) & BDFS_DEDUP_MASK;
			if (test_bit(wh_h, rc->seen))
				return true; /* whited out; skip */
		}

		if (bdfs_dedup_test_set(rc, name, namlen))
			return true; /* duplicate upper entry; skip */
	} else {
		/*
		 * Upper-layer pass: record every name (including whiteout
		 * names) so the lower pass can detect both duplicates and
		 * whited-out entries via the dedup bitmap.
		 */
		bdfs_dedup_test_set(rc, name, namlen);
	}

	return dir_emit(rc->caller_ctx, name, namlen, ino, d_type);
}

static int bdfs_blend_iterate_shared(struct file *file,
				     struct dir_context *caller_ctx)
{
	struct inode *inode = file_inode(file);
	struct bdfs_blend_inode_info *bi = BDFS_I(inode);
	struct super_block *sb = inode->i_sb;
	struct bdfs_blend_mount *bm = sb->s_fs_info;
	struct bdfs_readdir_ctx rc;
	struct file *real_file;
	struct bdfs_dwarfs_layer *layer;
	int ret = 0;

	memset(&rc, 0, sizeof(rc));
	rc.ctx.actor  = bdfs_filldir;
	rc.ctx.pos    = caller_ctx->pos;
	rc.caller_ctx = caller_ctx;
	rc.dedup      = false; /* first pass: record names */

	/* Pass 1: BTRFS upper layer */
	if (bm && bm->btrfs_mnt && bi->real_path.dentry) {
		real_file = dentry_open(&bi->real_path,
					O_RDONLY | O_DIRECTORY,
					current_cred());
		if (!IS_ERR(real_file)) {
			ret = iterate_dir(real_file, &rc.ctx);
			fput(real_file);
		}
	}

	/* Pass 2: DwarFS lower layers — skip names seen in upper */
	rc.dedup = true;
	if (bm) {
		list_for_each_entry(layer, &bm->dwarfs_layers, list) {
			struct path lower_path;
			char *relpath_buf;
			char *relpath;
			int err;

			if (!layer->mnt)
				continue;

			/*
			 * Build the full relative path from the layer root to
			 * this directory (e.g. "usr/share/doc") so that nested
			 * directories are resolved correctly.  Using only the
			 * final dentry name component would fail for any
			 * directory that is not at the top level of the layer.
			 */
			relpath_buf = kmalloc(PATH_MAX, GFP_KERNEL);
			if (!relpath_buf)
				continue;

			relpath = bdfs_blend_rel_path(bi->real_path.dentry,
						      relpath_buf, PATH_MAX);
			if (IS_ERR(relpath)) {
				kfree(relpath_buf);
				continue;
			}

			err = vfs_path_lookup(layer->mnt->mnt_root,
					      layer->mnt,
					      relpath,
					      0, &lower_path);
			kfree(relpath_buf);
			if (err)
				continue;

			real_file = dentry_open(&lower_path,
						O_RDONLY | O_DIRECTORY,
						current_cred());
			path_put(&lower_path);
			if (IS_ERR(real_file))
				continue;

			rc.ctx.pos = 0;
			iterate_dir(real_file, &rc.ctx);
			fput(real_file);
		}
	}

	caller_ctx->pos = rc.ctx.pos;
	return ret;
}

/* ── Cached write_iter ───────────────────────────────────────────────────── */

/*
 * bdfs_blend_write_iter - Forward writes to the BTRFS upper layer.
 *
 * The upper-layer file is opened once and cached in bi->upper_file.
 * Subsequent writes reuse the cached file, avoiding a dentry_open() per call.
 * The cache is invalidated (and the file closed) in bdfs_blend_free_inode().
 */
static ssize_t bdfs_blend_write_iter(struct kiocb *iocb, struct iov_iter *iter)
{
	struct file *file = iocb->ki_filp;
	struct inode *inode = file_inode(file);
	struct bdfs_blend_inode_info *bi = BDFS_I(inode);
	ssize_t ret;

	if (!bi->is_upper)
		return -EROFS;

	/* Open and cache the upper-layer file on first write */
	if (!bi->upper_file) {
		struct file *uf = dentry_open(&bi->real_path,
					      O_RDWR | O_LARGEFILE,
					      current_cred());
		if (IS_ERR(uf))
			return PTR_ERR(uf);
		bi->upper_file = uf;
	}

	iocb->ki_filp = bi->upper_file;
	ret = bi->upper_file->f_op->write_iter(iocb, iter);
	iocb->ki_filp = file;

	/* Sync size back to the blend inode */
	inode->i_size = file_inode(bi->upper_file)->i_size;
	return ret;
}

/* ── fsync ───────────────────────────────────────────────────────────────── */

/*
 * bdfs_blend_fsync - Forward fsync to the real backing file.
 *
 * For upper-layer (BTRFS) files we open the real file and call its fsync.
 * For lower-layer (DwarFS) files fsync is a no-op: DwarFS images are
 * read-only and already fully persisted.
 *
 * datasync semantics are preserved: if datasync is set we call ->fsync with
 * datasync=1 on the real file, which BTRFS maps to fdatawrite + wait.
 */
static int bdfs_blend_fsync(struct file *file, loff_t start, loff_t end,
			    int datasync)
{
	struct inode *inode = file_inode(file);
	struct bdfs_blend_inode_info *bi = BDFS_I(inode);
	struct file *real_file;
	int ret;

	/* Lower-layer (DwarFS) files are read-only — nothing to flush. */
	if (!bi->is_upper)
		return 0;

	/*
	 * Use the cached upper_file if available; otherwise open the real
	 * dentry directly.  We do not cache the file here because fsync may
	 * be called without a preceding write (e.g. after O_SYNC open).
	 */
	if (bi->upper_file) {
		real_file = bi->upper_file;
		get_file(real_file);
	} else {
		real_file = dentry_open(&bi->real_path, O_RDWR | O_LARGEFILE,
					current_cred());
		if (IS_ERR(real_file))
			return PTR_ERR(real_file);
	}

	if (real_file->f_op && real_file->f_op->fsync)
		ret = real_file->f_op->fsync(real_file, start, end, datasync);
	else
		ret = generic_file_fsync(real_file, start, end, datasync);

	fput(real_file);
	return ret;
}

/* ── mmap ────────────────────────────────────────────────────────────────── */

/*
 * bdfs_blend_mmap - Map a blend file into the process address space.
 *
 * Read-only mappings of lower-layer (DwarFS) files are forwarded directly
 * to the DwarFS FUSE file's mmap handler.  Write mappings trigger copy-up
 * first (same as write_iter) and then forward to the BTRFS upper file.
 *
 * Kernel version notes:
 *   - generic_file_mmap() is available on all supported kernels (≥5.15).
 *   - The vma->vm_file swap pattern is the standard stackable-fs approach
 *     used by overlayfs since 4.19.
 */
static int bdfs_blend_mmap(struct file *file, struct vm_area_struct *vma)
{
	struct inode *inode = file_inode(file);
	struct bdfs_blend_inode_info *bi = BDFS_I(inode);
	struct super_block *sb = inode->i_sb;
	struct bdfs_blend_mount *bm = sb->s_fs_info;
	struct file *real_file;
	int ret;

	/* Write mapping on a lower-layer inode requires copy-up first. */
	if (!bi->is_upper && (vma->vm_flags & VM_WRITE)) {
		ret = bdfs_blend_trigger_copyup(inode, bm);
		if (ret)
			return ret;
	}

	/*
	 * Open the real backing file for the mapping.  We use the cached
	 * upper_file for upper-layer inodes to avoid redundant dentry_open
	 * calls; for lower-layer read-only mappings we open fresh.
	 */
	if (bi->is_upper && bi->upper_file) {
		real_file = bi->upper_file;
		get_file(real_file);
	} else {
		int flags = bi->is_upper ? (O_RDWR | O_LARGEFILE)
					 : (O_RDONLY | O_LARGEFILE);
		real_file = dentry_open(&bi->real_path, flags, current_cred());
		if (IS_ERR(real_file))
			return PTR_ERR(real_file);
	}

	if (!real_file->f_op || !real_file->f_op->mmap) {
		fput(real_file);
		return -ENODEV;
	}

	/*
	 * Swap vm_file to the real file so that page-fault handlers and
	 * writeback operate on the real inode, not the blend inode.
	 * This is the same technique used by overlayfs.
	 *
	 * vma_set_file() was introduced in 5.17 (commit 3fcd3e4).  On
	 * 5.15/5.16 we open-code the equivalent.  In both cases real_file
	 * already holds an extra reference from get_file() / dentry_open()
	 * above, which becomes the vma's reference.  We do NOT fput() here;
	 * the VFS releases vma->vm_file when the VMA is destroyed.
	 */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 17, 0)
	vma_set_file(vma, real_file);
	/* vma_set_file() takes its own get_file(); release our ref. */
	fput(real_file);
#else
	/* Manually install real_file as vma->vm_file, consuming our ref. */
	{
		struct file *old = vma->vm_file;
		vma->vm_file = real_file; /* transfers our ref to the vma */
		if (old)
			fput(old);
	}
#endif
	ret = vma->vm_file->f_op->mmap(vma->vm_file, vma);
	return ret;
}

/* ── xattr set / get ─────────────────────────────────────────────────────── */

/*
 * bdfs_blend_setxattr - Set an extended attribute on a blend inode.
 *
 * Always targets the BTRFS upper layer.  If the inode is currently on a
 * lower layer, copy-up is triggered first.
 *
 * Kernel version notes:
 *   vfs_setxattr() signature is stable across 5.15–6.15.  The idmap
 *   parameter was added in 6.0; we use mnt_idmap(bi->real_path.mnt) which
 *   returns &nop_mnt_idmap on kernels that don't support idmapped mounts.
 */
static int bdfs_blend_setxattr(const struct xattr_handler *handler,
			       struct mnt_idmap *idmap,
			       struct dentry *dentry, struct inode *inode,
			       const char *name, const void *value,
			       size_t size, int flags)
{
	struct bdfs_blend_inode_info *bi = BDFS_I(inode);
	struct super_block *sb = inode->i_sb;
	struct bdfs_blend_mount *bm = sb->s_fs_info;
	struct mnt_idmap *real_idmap;
	int ret;

	if (!bi->is_upper) {
		ret = bdfs_blend_trigger_copyup(inode, bm);
		if (ret)
			return ret;
	}

	real_idmap = mnt_idmap(bi->real_path.mnt);
	return vfs_setxattr(real_idmap, bi->real_path.dentry, name,
			    value, size, flags);
}

/*
 * bdfs_blend_getxattr - Get an extended attribute from a blend inode.
 *
 * Reads from whichever layer currently backs the inode.  For upper-layer
 * inodes this is the BTRFS file; for lower-layer inodes this is the DwarFS
 * FUSE file (DwarFS preserves xattrs from the source tree).
 */
static int bdfs_blend_getxattr(const struct xattr_handler *handler,
			       struct dentry *dentry, struct inode *inode,
			       const char *name, void *value, size_t size)
{
	struct bdfs_blend_inode_info *bi = BDFS_I(inode);

	if (!bi->real_path.dentry)
		return -EIO;

	return vfs_getxattr(mnt_idmap(bi->real_path.mnt),
			    bi->real_path.dentry, name, value, size);
}

/*
 * Xattr handler table.  We register a catch-all handler (prefix="") so that
 * all xattr namespaces (user., trusted., security., system.) are routed
 * through our set/get implementations.
 *
 * Kernel version note: the catch-all empty-prefix handler is supported since
 * 4.9 (commit 2a7dba391).  On older kernels each namespace needs its own
 * handler entry — but we target ≥5.15 so this is fine.
 */
static const struct xattr_handler bdfs_blend_xattr_handler = {
	.prefix = "",   /* match all namespaces */
	.get    = bdfs_blend_getxattr,
	.set    = bdfs_blend_setxattr,
};

static const struct xattr_handler * const bdfs_blend_xattr_handlers[] = {
	&bdfs_blend_xattr_handler,
	NULL,
};

/* ── permission ──────────────────────────────────────────────────────────── */

/*
 * bdfs_blend_permission - Check access permission against the real inode.
 *
 * generic_permission() only consults the blend inode's cached uid/gid/mode,
 * which we keep in sync via bdfs_blend_getattr.  However, POSIX ACLs are
 * stored as xattrs on the real inode and are not reflected in the blend
 * inode's i_acl pointer.  We therefore delegate to the real inode's
 * ->permission handler (or generic_permission if it has none), passing the
 * real inode's idmap so that idmapped-mount ACL checks work correctly.
 *
 * Kernel version notes:
 *   - inode_permission() is available on all supported kernels.
 *   - mnt_idmap() returning &nop_mnt_idmap on non-idmapped mounts is
 *     correct behaviour (no mapping applied).
 *   - On kernels < 6.0 the idmap parameter to ->permission did not exist;
 *     we use the preprocessor guard already established in this file.
 */
static int bdfs_blend_permission(struct mnt_idmap *idmap,
				 struct inode *inode, int mask)
{
	struct bdfs_blend_inode_info *bi = BDFS_I(inode);
	struct inode *real;
	struct mnt_idmap *real_idmap;

	if (!bi->real_path.dentry)
		return -EIO;

	real = d_inode(bi->real_path.dentry);
	real_idmap = mnt_idmap(bi->real_path.mnt);

	/*
	 * Refresh cached credentials from the real inode so that
	 * generic_permission (called by inode_permission) sees current values.
	 */
	inode->i_uid  = real->i_uid;
	inode->i_gid  = real->i_gid;
	inode->i_mode = (inode->i_mode & S_IFMT) | (real->i_mode & ~S_IFMT);

	if (real->i_op && real->i_op->permission)
		return real->i_op->permission(real_idmap, real, mask);

	return generic_permission(real_idmap, real, mask);
}

/* ── whiteout helpers ────────────────────────────────────────────────────── */

/*
 * bdfs_blend_whiteout_name - Build the whiteout filename for a given name.
 *
 * Writes ".wh.<name>\0" into buf (which must be at least
 * BDFS_WH_PREFIX_LEN + namelen + 1 bytes).  Returns buf on success or
 * ERR_PTR(-ENAMETOOLONG) if the result would exceed NAME_MAX.
 */
static char *bdfs_blend_whiteout_name(const char *name, size_t namelen,
				      char *buf, size_t bufsz)
{
	if (BDFS_WH_PREFIX_LEN + namelen + 1 > bufsz ||
	    BDFS_WH_PREFIX_LEN + namelen > NAME_MAX)
		return ERR_PTR(-ENAMETOOLONG);

	memcpy(buf, BDFS_WH_PREFIX, BDFS_WH_PREFIX_LEN);
	memcpy(buf + BDFS_WH_PREFIX_LEN, name, namelen);
	buf[BDFS_WH_PREFIX_LEN + namelen] = '\0';
	return buf;
}

/*
 * bdfs_blend_is_whiteout - Return true if dentry is a whiteout marker.
 *
 * A whiteout is a zero-length regular file whose name starts with ".wh.".
 * We check both the name prefix and the file type to avoid false positives
 * from user files that happen to start with ".wh.".
 */
static bool bdfs_blend_is_whiteout(struct dentry *dentry)
{
	struct inode *inode;

	if (!dentry || d_is_negative(dentry))
		return false;
	if (!str_has_prefix(dentry->d_name.name, BDFS_WH_PREFIX))
		return false;

	inode = d_inode(dentry);
	return inode && S_ISREG(inode->i_mode) && inode->i_size == 0;
}

/*
 * bdfs_blend_check_whiteout - Check whether the upper layer has whited out
 * a name that exists on a lower layer.
 *
 * Looks up ".wh.<name>" in the upper-layer directory corresponding to
 * parent_bi.  Returns true if a whiteout exists (lower entry should be
 * hidden), false otherwise.
 *
 * Called from bdfs_blend_lookup and bdfs_blend_iterate_shared.
 */
static bool bdfs_blend_check_whiteout(struct bdfs_blend_inode_info *parent_bi,
				      const char *name, size_t namelen)
{
	char wh_buf[NAME_MAX + BDFS_WH_PREFIX_LEN + 1];
	char *wh_name;
	struct dentry *parent_dentry;
	struct dentry *wh_dentry;
	bool found = false;

	if (!parent_bi->is_upper || !parent_bi->real_path.dentry)
		return false;

	wh_name = bdfs_blend_whiteout_name(name, namelen,
					   wh_buf, sizeof(wh_buf));
	if (IS_ERR(wh_name))
		return false;

	parent_dentry = parent_bi->real_path.dentry;

	/*
	 * lookup_one() requires the parent inode lock.  We take it briefly
	 * here; this is safe because bdfs_blend_check_whiteout is called
	 * from bdfs_blend_lookup (which holds no inode locks) and from
	 * bdfs_filldir (which holds the directory file lock, not the inode
	 * lock).
	 *
	 * Kernel version note: lookup_one() signature is stable across
	 * 5.15–6.15.  lookup_one_unlocked() was removed in 6.4 (it was
	 * only ever an internal helper); we use lookup_one() throughout.
	 */
	inode_lock_shared(d_inode(parent_dentry));
	wh_dentry = lookup_one(mnt_idmap(parent_bi->real_path.mnt),
			       wh_name, parent_dentry, strlen(wh_name));
	inode_unlock_shared(d_inode(parent_dentry));

	if (IS_ERR(wh_dentry))
		return false;

	found = bdfs_blend_is_whiteout(wh_dentry);
	dput(wh_dentry);
	return found;
}

/*
 * bdfs_blend_create_whiteout - Create a whiteout marker on the upper layer.
 *
 * Creates ".wh.<name>" as a zero-length regular file in the upper-layer
 * directory.  Called from bdfs_blend_unlink and bdfs_blend_rmdir when the
 * target exists on a lower layer (so we cannot actually delete it there).
 *
 * If the upper-layer directory does not yet exist (the parent is still on
 * the lower layer), copy-up of the parent directory is triggered first.
 */
static int bdfs_blend_create_whiteout(struct inode *dir,
				      const char *name, size_t namelen,
				      struct bdfs_blend_mount *bm)
{
	struct bdfs_blend_inode_info *parent_bi = BDFS_I(dir);
	char wh_buf[NAME_MAX + BDFS_WH_PREFIX_LEN + 1];
	char *wh_name;
	struct dentry *parent_dentry;
	struct dentry *wh_dentry;
	struct mnt_idmap *idmap;
	int ret;

	/* Ensure the parent directory is on the upper layer. */
	if (!parent_bi->is_upper) {
		ret = bdfs_blend_trigger_copyup(dir, bm);
		if (ret)
			return ret;
	}

	wh_name = bdfs_blend_whiteout_name(name, namelen,
					   wh_buf, sizeof(wh_buf));
	if (IS_ERR(wh_name))
		return PTR_ERR(wh_name);

	parent_dentry = parent_bi->real_path.dentry;
	idmap = mnt_idmap(parent_bi->real_path.mnt);

	inode_lock(d_inode(parent_dentry));
	wh_dentry = lookup_one(idmap, wh_name, parent_dentry, strlen(wh_name));
	if (IS_ERR(wh_dentry)) {
		inode_unlock(d_inode(parent_dentry));
		return PTR_ERR(wh_dentry);
	}

	if (d_is_positive(wh_dentry)) {
		/* Whiteout already exists — nothing to do. */
		dput(wh_dentry);
		inode_unlock(d_inode(parent_dentry));
		return 0;
	}

	ret = vfs_create(idmap, d_inode(parent_dentry), wh_dentry,
			 S_IFREG | 0000, false);
	dput(wh_dentry);
	inode_unlock(d_inode(parent_dentry));
	return ret;
}

/* ── copy_file_range ─────────────────────────────────────────────────────── */

/*
 * bdfs_blend_copy_file_range - Forward copy_file_range to the real files.
 *
 * Both source and destination must be on the upper (BTRFS) layer for an
 * in-kernel copy to be possible.  If the source is on a lower (DwarFS) layer
 * we fall back to the generic VFS implementation which reads and writes via
 * read_iter/write_iter (triggering copy-up on the destination as needed).
 *
 * The fast path uses vfs_copy_file_range() on the real backing files so that
 * BTRFS can use its native reflink/clone_range ioctl for zero-copy within
 * the same filesystem.
 *
 * Kernel version notes:
 *   vfs_copy_file_range() is stable across 5.15–6.15.
 *   do_splice_direct() used in the fallback is also stable.
 */
static ssize_t bdfs_blend_copy_file_range(struct file *file_in,
					  loff_t pos_in,
					  struct file *file_out,
					  loff_t pos_out,
					  size_t len, unsigned int flags)
{
	struct bdfs_blend_inode_info *bi_in  = BDFS_I(file_inode(file_in));
	struct bdfs_blend_inode_info *bi_out = BDFS_I(file_inode(file_out));
	struct super_block *sb = file_inode(file_out)->i_sb;
	struct bdfs_blend_mount *bm = sb->s_fs_info;
	struct file *real_in  = NULL;
	struct file *real_out = NULL;
	ssize_t ret;

	/*
	 * Destination must be on the upper layer (writes always go to BTRFS).
	 * Trigger copy-up if it is currently lower-layer.
	 */
	if (!bi_out->is_upper) {
		ret = bdfs_blend_trigger_copyup(file_inode(file_out), bm);
		if (ret)
			return ret;
	}

	/*
	 * Fast path: both files are on the upper (BTRFS) layer.
	 * Open real backing files and call vfs_copy_file_range so BTRFS can
	 * use reflink/clone_range for a zero-copy operation.
	 */
	if (bi_in->is_upper && bi_out->is_upper) {
		int in_flags  = O_RDONLY | O_LARGEFILE;
		int out_flags = O_RDWR   | O_LARGEFILE;

		real_in = bi_in->upper_file
			  ? (get_file(bi_in->upper_file), bi_in->upper_file)
			  : dentry_open(&bi_in->real_path, in_flags,
					current_cred());
		if (IS_ERR(real_in))
			return PTR_ERR(real_in);

		real_out = bi_out->upper_file
			   ? (get_file(bi_out->upper_file), bi_out->upper_file)
			   : dentry_open(&bi_out->real_path, out_flags,
					 current_cred());
		if (IS_ERR(real_out)) {
			fput(real_in);
			return PTR_ERR(real_out);
		}

		ret = vfs_copy_file_range(real_in, pos_in,
					  real_out, pos_out, len, flags);
		fput(real_in);
		fput(real_out);
		return ret;
	}

	/*
	 * Slow path: source is on a lower (DwarFS) layer.  Fall back to the
	 * generic implementation which uses read_iter + write_iter.  This is
	 * correct but not zero-copy.
	 */
	return generic_copy_file_range(file_in, pos_in,
				       file_out, pos_out, len, flags);
}

/* ── FS_IOC_GETFLAGS / FS_IOC_SETFLAGS ──────────────────────────────────── */

/*
 * bdfs_blend_ioctl - Forward FS_IOC_GETFLAGS and FS_IOC_SETFLAGS to the
 * real backing inode.
 *
 * These ioctls read/write the inode flags word (FS_IMMUTABLE_FL,
 * FS_APPEND_FL, FS_NOATIME_FL, etc.) stored in the real filesystem.
 * We open the real file and call its ->unlocked_ioctl handler directly.
 *
 * FS_IOC_SETFLAGS on a lower-layer inode triggers copy-up first (the flag
 * change is a mutation and must land on the BTRFS upper layer).
 *
 * Kernel version notes:
 *   fileattr_get / fileattr_set (introduced in 5.13) are the modern
 *   interface; FS_IOC_GETFLAGS/SETFLAGS are the legacy ioctl numbers that
 *   BTRFS still handles via its ->unlocked_ioctl.  We use the ioctl path
 *   because it works across all supported kernel versions (5.15–6.15) and
 *   avoids the need to call ->fileattr_get/set which may not be set on the
 *   DwarFS FUSE inode.
 */
static long bdfs_blend_ioctl(struct file *file, unsigned int cmd,
			     unsigned long arg)
{
	struct inode *inode = file_inode(file);
	struct bdfs_blend_inode_info *bi = BDFS_I(inode);
	struct super_block *sb = inode->i_sb;
	struct bdfs_blend_mount *bm = sb->s_fs_info;
	struct file *real_file;
	long ret;

	switch (cmd) {
	case FS_IOC_GETFLAGS:
	case FS_IOC_SETFLAGS:
#ifdef CONFIG_COMPAT
	case FS_IOC32_GETFLAGS:
	case FS_IOC32_SETFLAGS:
#endif
		break;
	default:
		return -ENOTTY;
	}

	/* Mutations require the upper layer; trigger copy-up if needed. */
	if ((cmd == FS_IOC_SETFLAGS
#ifdef CONFIG_COMPAT
	     || cmd == FS_IOC32_SETFLAGS
#endif
	    ) && !bi->is_upper) {
		ret = bdfs_blend_trigger_copyup(inode, bm);
		if (ret)
			return ret;
	}

	/* Open the real backing file. */
	{
		int open_flags = (cmd == FS_IOC_GETFLAGS
#ifdef CONFIG_COMPAT
				  || cmd == FS_IOC32_GETFLAGS
#endif
				 ) ? (O_RDONLY | O_LARGEFILE)
				   : (O_RDWR   | O_LARGEFILE);

		if (bi->is_upper && bi->upper_file) {
			real_file = bi->upper_file;
			get_file(real_file);
		} else {
			real_file = dentry_open(&bi->real_path, open_flags,
						current_cred());
			if (IS_ERR(real_file))
				return PTR_ERR(real_file);
		}
	}

	if (real_file->f_op && real_file->f_op->unlocked_ioctl)
		ret = real_file->f_op->unlocked_ioctl(real_file, cmd, arg);
	else
		ret = -ENOTTY;

	fput(real_file);
	return ret;
}

#ifdef CONFIG_COMPAT
static long bdfs_blend_compat_ioctl(struct file *file, unsigned int cmd,
				    unsigned long arg)
{
	/* Translate 32-bit ioctl numbers and forward. */
	switch (cmd) {
	case FS_IOC32_GETFLAGS:
		return bdfs_blend_ioctl(file, FS_IOC_GETFLAGS, arg);
	case FS_IOC32_SETFLAGS:
		return bdfs_blend_ioctl(file, FS_IOC_SETFLAGS, arg);
	default:
		return -ENOIOCTLCMD;
	}
}
#endif

/* ── inode_operations / file_operations tables ───────────────────────────── */

static const struct inode_operations bdfs_blend_symlink_iops = {
	.get_link   = bdfs_blend_get_link,
	.getattr    = bdfs_blend_getattr,
	.permission = bdfs_blend_permission,
};

static const struct inode_operations bdfs_blend_file_iops = {
	.getattr    = bdfs_blend_getattr,
	.setattr    = bdfs_blend_setattr,
	.listxattr  = bdfs_blend_listxattr,
	.permission = bdfs_blend_permission,
};

static const struct file_operations bdfs_blend_file_fops = {
	.open             = bdfs_blend_open,
	.read_iter        = generic_file_read_iter,
	.write_iter       = bdfs_blend_write_iter,
	.mmap             = bdfs_blend_mmap,
	.llseek           = generic_file_llseek,
	.fsync            = bdfs_blend_fsync,
	.copy_file_range  = bdfs_blend_copy_file_range,
	.unlocked_ioctl   = bdfs_blend_ioctl,
#ifdef CONFIG_COMPAT
	.compat_ioctl     = bdfs_blend_compat_ioctl,
#endif
};

static const struct file_operations bdfs_blend_dir_fops = {
	.iterate_shared = bdfs_blend_iterate_shared,
	.llseek         = generic_file_llseek,
	.fsync          = bdfs_blend_fsync,
};

static const struct inode_operations bdfs_blend_dir_iops = {
	.lookup      = bdfs_blend_lookup,
	.getattr     = bdfs_blend_getattr,
	.setattr     = bdfs_blend_setattr,
	.listxattr   = bdfs_blend_listxattr,
	.permission  = bdfs_blend_permission,
	.create      = bdfs_blend_create,
	.mkdir       = bdfs_blend_mkdir,
	.unlink      = bdfs_blend_unlink,
	.rmdir       = bdfs_blend_rmdir,
	.rename      = bdfs_blend_rename,
	.symlink     = bdfs_blend_symlink,
	.link        = bdfs_blend_link,
};

/* ── Filesystem type registration ───────────────────────────────────────── */

static int bdfs_blend_fill_super(struct super_block *sb, struct fs_context *fc)
{
	struct bdfs_blend_mount *bm = fc->fs_private;
	struct inode *root_inode;
	struct dentry *root_dentry;

	sb->s_magic   = BDFS_BLEND_MAGIC;
	sb->s_op      = &bdfs_blend_sops;
	sb->s_xattr   = bdfs_blend_xattr_handlers;
	sb->s_fs_info = bm;
	bm->sb = sb;   /* back-pointer so bdfs_blend_umount can deactivate_super */

	root_inode = new_inode(sb);
	if (!root_inode)
		return -ENOMEM;

	root_inode->i_ino  = 1;
	root_inode->i_mode = S_IFDIR | 0755;
	root_inode->i_op   = &bdfs_blend_dir_iops;
	root_inode->i_fop  = &bdfs_blend_dir_fops;
	set_nlink(root_inode, 2);

	root_dentry = d_make_root(root_inode);
	if (!root_dentry)
		return -ENOMEM;

	sb->s_root = root_dentry;
	return 0;
}

static int bdfs_blend_get_tree(struct fs_context *fc)
{
	return get_tree_nodev(fc, bdfs_blend_fill_super);
}

static const struct fs_context_operations bdfs_blend_ctx_ops = {
	.get_tree = bdfs_blend_get_tree,
};

static int bdfs_blend_init_fs_context(struct fs_context *fc)
{
	struct bdfs_blend_mount *bm;

	bm = kzalloc(sizeof(*bm), GFP_KERNEL);
	if (!bm)
		return -ENOMEM;

	INIT_LIST_HEAD(&bm->dwarfs_layers);
	fc->fs_private = bm;
	fc->ops = &bdfs_blend_ctx_ops;
	return 0;
}

static struct file_system_type bdfs_blend_fs_type = {
	.owner            = THIS_MODULE,
	.name             = BDFS_BLEND_FS_TYPE,
	.init_fs_context  = bdfs_blend_init_fs_context,
	.kill_sb          = kill_anon_super,
};

/* ── Blend mount / umount ioctls ─────────────────────────────────────────── */

int bdfs_blend_mount(void __user *uarg,
		     struct list_head *registry,
		     struct mutex *lock)
{
	struct bdfs_ioctl_mount_blend arg;
	struct bdfs_blend_mount *bm;
	char event_msg[256];

	if (copy_from_user(&arg, uarg, sizeof(arg)))
		return -EFAULT;

	bm = kzalloc(sizeof(*bm), GFP_KERNEL);
	if (!bm)
		return -ENOMEM;

	INIT_LIST_HEAD(&bm->dwarfs_layers);
	memcpy(bm->btrfs_uuid, arg.btrfs_uuid, 16);
	strscpy(bm->mount_point, arg.mount_point, sizeof(bm->mount_point));
	memcpy(&bm->opts, &arg.opts, sizeof(bm->opts));

	mutex_lock(&bdfs_blend_mounts_lock);
	list_add_tail(&bm->list, &bdfs_blend_mounts);
	mutex_unlock(&bdfs_blend_mounts_lock);

	snprintf(event_msg, sizeof(event_msg),
		 "blend mount=%s btrfs_uuid=%*phN dwarfs_uuid=%*phN",
		 arg.mount_point, 16, arg.btrfs_uuid, 16, arg.dwarfs_uuid);
	bdfs_emit_event(BDFS_EVT_BLEND_MOUNTED, arg.btrfs_uuid, 0, event_msg);

	pr_info("bdfs: blend mount queued at %s\n", arg.mount_point);
	return 0;
}

/*
 * bdfs_blend_attach_mounts - Wire daemon-resolved vfsmounts into a blend mount.
 *
 * Called via BDFS_IOC_BLEND_ATTACH_MOUNTS after the daemon has mounted the
 * BTRFS upper layer and all DwarFS lower layers in userspace.  The daemon
 * passes O_PATH file descriptors; we extract the vfsmount from each fd via
 * fdget(), take a mntget() reference, and store it in the bdfs_blend_mount.
 *
 * Using O_PATH fds is the correct kernel interface for passing vfsmount
 * references across the userspace/kernel boundary without requiring the
 * caller to have CAP_SYS_ADMIN for kern_mount().
 *
 * Kernel version notes:
 *   fdget() + real_mount() is stable across 5.15–6.15.
 *   real_mount() is defined in fs/mount.h (included via mount.h).
 */
int bdfs_blend_attach_mounts(void __user *uarg)
{
	struct bdfs_ioctl_blend_attach_mounts arg;
	struct bdfs_blend_mount *bm;
	struct fd f;
	struct vfsmount *mnt;
	bool found = false;
	u32 i;

	if (copy_from_user(&arg, uarg, sizeof(arg)))
		return -EFAULT;

	if (arg.n_dwarfs > BDFS_MAX_DWARFS_LAYERS)
		return -EINVAL;

	/* Find the blend mount by mount_point string. */
	mutex_lock(&bdfs_blend_mounts_lock);
	list_for_each_entry(bm, &bdfs_blend_mounts, list) {
		if (strcmp(bm->mount_point, arg.mount_point) == 0) {
			found = true;
			break;
		}
	}
	mutex_unlock(&bdfs_blend_mounts_lock);

	if (!found)
		return -ENOENT;

	/* Attach BTRFS upper-layer mount. */
	if (arg.btrfs_fd >= 0) {
		f = fdget(arg.btrfs_fd);
		if (!f.file)
			return -EBADF;
		mnt = mntget(f.file->f_path.mnt);
		fdput(f);

		/* Drop any previous reference. */
		if (bm->btrfs_mnt)
			mntput(bm->btrfs_mnt);
		bm->btrfs_mnt = mnt;
	}

	/* Attach DwarFS lower-layer mounts. */
	for (i = 0; i < arg.n_dwarfs; i++) {
		struct bdfs_dwarfs_layer *layer;

		if (arg.dwarfs_fds[i] < 0)
			continue;

		f = fdget(arg.dwarfs_fds[i]);
		if (!f.file)
			continue;
		mnt = mntget(f.file->f_path.mnt);
		fdput(f);

		/* Find or allocate the layer slot. */
		layer = NULL;
		{
			struct bdfs_dwarfs_layer *l;
			u32 idx = 0;

			list_for_each_entry(l, &bm->dwarfs_layers, list) {
				if (idx == i) {
					layer = l;
					break;
				}
				idx++;
			}
		}

		if (!layer) {
			layer = kzalloc(sizeof(*layer), GFP_KERNEL);
			if (!layer) {
				mntput(mnt);
				return -ENOMEM;
			}
			list_add_tail(&layer->list, &bm->dwarfs_layers);
		} else if (layer->mnt) {
			mntput(layer->mnt);
		}

		layer->mnt = mnt;
	}

	pr_info("bdfs: attached mounts for blend at %s (btrfs=%s, dwarfs_layers=%u)\n",
		arg.mount_point,
		bm->btrfs_mnt ? "ok" : "none",
		arg.n_dwarfs);
	return 0;
}

int bdfs_blend_umount(void __user *uarg)
{
	struct bdfs_ioctl_umount_blend arg;
	struct bdfs_blend_mount *bm, *tmp;
	struct super_block *sb_to_deactivate = NULL;
	struct bdfs_dwarfs_layer *layer, *ltmp;
	bool found = false;

	if (copy_from_user(&arg, uarg, sizeof(arg)))
		return -EFAULT;

	mutex_lock(&bdfs_blend_mounts_lock);
	list_for_each_entry_safe(bm, tmp, &bdfs_blend_mounts, list) {
		if (strcmp(bm->mount_point, arg.mount_point) != 0)
			continue;

		list_del(&bm->list);
		found = true;

		bdfs_emit_event(BDFS_EVT_BLEND_UNMOUNTED,
				bm->btrfs_uuid, 0, arg.mount_point);

		/*
		 * Save the superblock pointer so we can call
		 * deactivate_super() after dropping the lock.
		 * deactivate_super() may sleep and must not be called
		 * under a mutex.
		 */
		sb_to_deactivate = bm->sb;

		/* Release BTRFS upper-layer mount reference */
		if (bm->btrfs_mnt) {
			mntput(bm->btrfs_mnt);
			bm->btrfs_mnt = NULL;
		}

		/* Release DwarFS lower-layer mount references */
		list_for_each_entry_safe(layer, ltmp,
					 &bm->dwarfs_layers, list) {
			list_del(&layer->list);
			if (layer->mnt)
				mntput(layer->mnt);
			kfree(layer);
		}

		kfree(bm);
		break;
	}
	mutex_unlock(&bdfs_blend_mounts_lock);

	if (!found)
		return -ENOENT;

	/*
	 * Deactivate the blend superblock.  This drops the active reference
	 * taken in bdfs_blend_mount() via get_tree_nodev(), allowing the VFS
	 * to evict all inodes and free the superblock when the last user
	 * releases it.
	 */
	if (sb_to_deactivate)
		deactivate_super(sb_to_deactivate);

	return 0;
}

/* ── BDFS_IOC_RESOLVE_PATH ──────────────────────────────────────────────── */

/*
 * bdfs_resolve_path - Resolve a blend-namespace path to its backing layer.
 *
 * Walks the blend mount list to find the mount whose mount_point is a prefix
 * of the requested path, then determines whether the path resolves to the
 * BTRFS upper layer or a DwarFS lower layer by attempting vfs_path_lookup on
 * each in priority order.
 *
 * Fills bdfs_ioctl_resolve_path.layer (BDFS_LAYER_UPPER / BDFS_LAYER_LOWER)
 * and .real_path with the resolved backing path.
 */
int bdfs_resolve_path(void __user *uarg,
		      struct list_head *registry,
		      struct mutex *lock)
{
	struct bdfs_ioctl_resolve_path arg;
	struct bdfs_blend_mount *bm;
	struct path resolved;
	bool found = false;
	int ret = -ENOENT;

	if (copy_from_user(&arg, uarg, sizeof(arg)))
		return -EFAULT;

	mutex_lock(&bdfs_blend_mounts_lock);
	list_for_each_entry(bm, &bdfs_blend_mounts, list) {
		size_t mlen = strlen(bm->mount_point);
		if (strncmp(arg.path, bm->mount_point, mlen) != 0)
			continue;

		/* Relative path within the blend mount */
		const char *rel = arg.path + mlen;
		if (*rel == '/')
			rel++;

		/* Try BTRFS upper layer first */
		ret = vfs_path_lookup(bm->btrfs_mnt->mnt_root,
				      bm->btrfs_mnt, rel, 0, &resolved);
		if (ret == 0) {
			arg.layer = BDFS_LAYER_UPPER;
			found = true;
			break;
		}

		/* Try each DwarFS lower layer */
		struct bdfs_dwarfs_layer *layer;
		list_for_each_entry(layer, &bm->dwarfs_layers, list) {
			if (!layer->mnt)
				continue;
			ret = vfs_path_lookup(layer->mnt->mnt_root,
					      layer->mnt, rel, 0, &resolved);
			if (ret == 0) {
				arg.layer = BDFS_LAYER_LOWER;
				found = true;
				break;
			}
		}
		if (found)
			break;
	}
	mutex_unlock(&bdfs_blend_mounts_lock);

	if (!found)
		return ret;

	/* Write the real path back to userspace */
	{
		char *buf = kmalloc(BDFS_PATH_MAX, GFP_KERNEL);
		if (!buf) {
			path_put(&resolved);
			return -ENOMEM;
		}
		char *p = d_path(&resolved, buf, BDFS_PATH_MAX);
		if (IS_ERR(p)) {
			kfree(buf);
			path_put(&resolved);
			return PTR_ERR(p);
		}
		strncpy(arg.real_path, p, sizeof(arg.real_path) - 1);
		kfree(buf);
		path_put(&resolved);
	}

	if (copy_to_user(uarg, &arg, sizeof(arg)))
		return -EFAULT;

	return 0;
}

/* ── Blend layer partition ops vtable ───────────────────────────────────── */

static int bdfs_blend_part_init(struct bdfs_partition_entry *entry)
{
	pr_info("bdfs: hybrid blend partition '%s' registered\n",
		entry->desc.label);
	return 0;
}

struct bdfs_part_ops bdfs_blend_part_ops = {
	.name = "hybrid_blend",
	.init = bdfs_blend_part_init,
};

/* ── Module-level init / exit ───────────────────────────────────────────── */

int bdfs_blend_init(void)
{
	int ret;

	bdfs_inode_cachep = kmem_cache_create(
		"bdfs_inode_cache",
		sizeof(struct bdfs_blend_inode_info), 0,
		BDFS_SLAB_FLAGS,
		bdfs_inode_init_once);
	if (!bdfs_inode_cachep) {
		pr_err("bdfs: failed to create inode cache\n");
		return -ENOMEM;
	}

	ret = register_filesystem(&bdfs_blend_fs_type);
	if (ret) {
		pr_err("bdfs: failed to register blend filesystem: %d\n", ret);
		kmem_cache_destroy(bdfs_inode_cachep);
		return ret;
	}

	pr_info("bdfs: blend filesystem type '%s' registered\n",
		BDFS_BLEND_FS_TYPE);
	return 0;
}

void bdfs_blend_exit(void)
{
	unregister_filesystem(&bdfs_blend_fs_type);
	/*
	 * rcu_barrier() ensures all RCU-deferred inode frees have completed
	 * before we destroy the cache.
	 */
	rcu_barrier();
	kmem_cache_destroy(bdfs_inode_cachep);
}

/* ── List partitions helper (used by bdfs_main.c) ───────────────────────── */

int bdfs_list_partitions(void __user *uarg,
			 struct list_head *registry,
			 struct mutex *lock)
{
	struct bdfs_ioctl_list_partitions arg;
	struct bdfs_partition_entry *entry;
	struct bdfs_partition __user *ubuf;
	u32 copied = 0, total = 0;

	if (copy_from_user(&arg, uarg, sizeof(arg)))
		return -EFAULT;

	ubuf = (struct bdfs_partition __user *)(uintptr_t)arg.parts;

	mutex_lock(lock);
	list_for_each_entry(entry, registry, list) {
		total++;
		if (copied < arg.count && ubuf) {
			if (copy_to_user(&ubuf[copied], &entry->desc,
					 sizeof(entry->desc))) {
				mutex_unlock(lock);
				return -EFAULT;
			}
			copied++;
		}
	}
	mutex_unlock(lock);

	if (put_user(copied, &((struct bdfs_ioctl_list_partitions __user *)uarg)->count))
		return -EFAULT;
	if (put_user(total, &((struct bdfs_ioctl_list_partitions __user *)uarg)->total))
		return -EFAULT;

	return 0;
}
