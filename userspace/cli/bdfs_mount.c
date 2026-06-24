// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * bdfs_mount.c - mount, umount, blend mount, blend umount subcommands
 *
 * bdfs mount --partition <uuid> --image-id <id>
 *            --mountpoint <path> [--cache-mb <n>]
 *
 * bdfs umount --partition <uuid> --image-id <id> [--force]
 *
 * bdfs blend mount --btrfs-uuid <uuid> --dwarfs-uuid <uuid>
 *                  --mountpoint <path>
 *                  [--btrfs-mount <path>] [--dwarfs-image <path>]
 *                  [--work-dir <path>]
 *                  [--compression zstd|...] [--cache-mb <n>]
 *                  [--writeback] [--lazy-load] [--userspace]
 *
 * bdfs blend umount --mountpoint <path> [--force] [--lazy]
 *
 * Blend mount mode selection
 * ──────────────────────────
 * By default `bdfs blend mount` sends BDFS_IOC_MOUNT_BLEND to the daemon,
 * which attempts a kernel bdfs_blend mount.  If the kernel module is not
 * loaded the ioctl returns ENODEV and the CLI automatically retries with
 * BDFS_IOC_MOUNT_BLEND_USERSPACE (fuse-overlayfs backend).
 *
 * Pass --userspace to skip the kernel attempt entirely.
 *
 * The userspace backend requires three additional arguments that the kernel
 * path derives internally:
 *   --btrfs-mount  <path>   writable BTRFS subvolume (upper layer)
 *   --dwarfs-image <path>   path to the .dwarfs image file (lower layer)
 *   --work-dir     <path>   overlayfs workdir (must be on same FS as upper)
 */
#define _GNU_SOURCE
#include <errno.h>
#include <getopt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include "bdfs.h"

/* ── mount ──────────────────────────────────────────────────────────────── */

int cmd_mount(struct bdfs_cli *cli, int argc, char *argv[])
{
	struct bdfs_ioctl_mount_dwarfs_image arg;
	int opt, ret;

	static const struct option opts[] = {
		{ "partition",  required_argument, NULL, 'p' },
		{ "image-id",   required_argument, NULL, 'I' },
		{ "mountpoint", required_argument, NULL, 'm' },
		{ "cache-mb",   required_argument, NULL, 'c' },
		{ "help",       no_argument,       NULL, 'h' },
		{ NULL, 0, NULL, 0 }
	};

	memset(&arg, 0, sizeof(arg));
	arg.cache_size_mb = 256;

	while ((opt = getopt_long(argc, argv, "p:I:m:c:h", opts, NULL)) != -1) {
		switch (opt) {
		case 'p':
			if (bdfs_str_to_uuid(optarg, arg.partition_uuid) < 0) {
				bdfs_err("invalid partition UUID: %s", optarg);
				return 1;
			}
			break;
		case 'I':
			arg.image_id = (uint64_t)strtoull(optarg, NULL, 0);
			break;
		case 'm':
			strncpy(arg.mount_point, optarg,
				sizeof(arg.mount_point) - 1);
			break;
		case 'c':
			arg.cache_size_mb = (uint32_t)atoi(optarg);
			break;
		case 'h':
			printf("Usage: bdfs mount --partition <uuid> "
			       "--image-id <id> --mountpoint <path> "
			       "[--cache-mb <n>]\n");
			return 0;
		default:
			return 1;
		}
	}

	if (!arg.mount_point[0]) {
		bdfs_err("--mountpoint is required");
		return 1;
	}

	ret = bdfs_cli_open_ctl(cli);
	if (ret) return 1;

	if (ioctl(cli->ctl_fd, BDFS_IOC_MOUNT_DWARFS_IMAGE, &arg) < 0) {
		bdfs_err("BDFS_IOC_MOUNT_DWARFS_IMAGE: %s", strerror(errno));
		return 1;
	}

	if (!cli->json_output)
		printf("Mount requested: image %llu → %s\n",
		       (unsigned long long)arg.image_id, arg.mount_point);
	return 0;
}

/* ── umount ─────────────────────────────────────────────────────────────── */

int cmd_umount(struct bdfs_cli *cli, int argc, char *argv[])
{
	struct bdfs_ioctl_umount_dwarfs_image arg;
	int opt, ret;

	static const struct option opts[] = {
		{ "partition", required_argument, NULL, 'p' },
		{ "image-id",  required_argument, NULL, 'I' },
		{ "force",     no_argument,       NULL, 'f' },
		{ "help",      no_argument,       NULL, 'h' },
		{ NULL, 0, NULL, 0 }
	};

	memset(&arg, 0, sizeof(arg));

	while ((opt = getopt_long(argc, argv, "p:I:fh", opts, NULL)) != -1) {
		switch (opt) {
		case 'p':
			if (bdfs_str_to_uuid(optarg, arg.partition_uuid) < 0) {
				bdfs_err("invalid partition UUID: %s", optarg);
				return 1;
			}
			break;
		case 'I':
			arg.image_id = (uint64_t)strtoull(optarg, NULL, 0);
			break;
		case 'f':
			arg.flags |= BDFS_UMOUNT_FORCE;
			break;
		case 'h':
			printf("Usage: bdfs umount --partition <uuid> "
			       "--image-id <id> [--force]\n");
			return 0;
		default:
			return 1;
		}
	}

	ret = bdfs_cli_open_ctl(cli);
	if (ret) return 1;

	if (ioctl(cli->ctl_fd, BDFS_IOC_UMOUNT_DWARFS_IMAGE, &arg) < 0) {
		bdfs_err("BDFS_IOC_UMOUNT_DWARFS_IMAGE: %s", strerror(errno));
		return 1;
	}

	if (!cli->json_output)
		printf("Unmounted image %llu\n",
		       (unsigned long long)arg.image_id);
	return 0;
}

/* ── blend mount ────────────────────────────────────────────────────────── */

int cmd_blend_mount(struct bdfs_cli *cli, int argc, char *argv[])
{
	/* Kernel-path arguments */
	struct bdfs_ioctl_mount_blend karg;
	/* Userspace-path arguments */
	struct bdfs_ioctl_mount_blend_userspace uarg;

	bool force_userspace = false;
	int  opt, ret;

	static const struct option opts[] = {
		{ "btrfs-uuid",   required_argument, NULL, 'B' },
		{ "dwarfs-uuid",  required_argument, NULL, 'D' },
		{ "mountpoint",   required_argument, NULL, 'm' },
		/* userspace-path extras */
		{ "btrfs-mount",  required_argument, NULL, 'b' },
		{ "dwarfs-image", required_argument, NULL, 'd' },
		{ "work-dir",     required_argument, NULL, 'W' },
		/* shared options */
		{ "compression",  required_argument, NULL, 'c' },
		{ "cache-mb",     required_argument, NULL, 'C' },
		{ "writeback",    no_argument,       NULL, 'w' },
		{ "lazy-load",    no_argument,       NULL, 'L' },
		{ "rdonly",       no_argument,       NULL, 'r' },
		{ "userspace",    no_argument,       NULL, 'u' },
		{ "help",         no_argument,       NULL, 'h' },
		{ NULL, 0, NULL, 0 }
	};

	memset(&karg, 0, sizeof(karg));
	memset(&uarg, 0, sizeof(uarg));
	karg.opts.cache_size_mb  = 256;
	karg.opts.worker_threads = 4;
	uarg.cache_size_mb       = 256;

	while ((opt = getopt_long(argc, argv,
				  "B:D:m:b:d:W:c:C:wLruh",
				  opts, NULL)) != -1) {
		switch (opt) {
		case 'B':
			if (bdfs_str_to_uuid(optarg, karg.btrfs_uuid) < 0 ||
			    bdfs_str_to_uuid(optarg, uarg.btrfs_uuid) < 0) {
				bdfs_err("invalid BTRFS UUID: %s", optarg);
				return 1;
			}
			break;
		case 'D':
			if (bdfs_str_to_uuid(optarg, karg.dwarfs_uuid) < 0 ||
			    bdfs_str_to_uuid(optarg, uarg.dwarfs_uuid) < 0) {
				bdfs_err("invalid DwarFS UUID: %s", optarg);
				return 1;
			}
			break;
		case 'm':
			strncpy(karg.mount_point, optarg,
				sizeof(karg.mount_point) - 1);
			strncpy(uarg.mount_point, optarg,
				sizeof(uarg.mount_point) - 1);
			break;
		case 'b':
			strncpy(uarg.btrfs_upper, optarg,
				sizeof(uarg.btrfs_upper) - 1);
			break;
		case 'd':
			strncpy(uarg.dwarfs_image, optarg,
				sizeof(uarg.dwarfs_image) - 1);
			break;
		case 'W':
			strncpy(uarg.work_dir, optarg,
				sizeof(uarg.work_dir) - 1);
			break;
		case 'c':
			karg.opts.compression =
				bdfs_compression_from_name(optarg);
			break;
		case 'C':
			karg.opts.cache_size_mb = (uint32_t)atoi(optarg);
			uarg.cache_size_mb      = (uint32_t)atoi(optarg);
			break;
		case 'w':
			karg.opts.flags |= BDFS_MOUNT_WRITEBACK;
			uarg.flags      |= BDFS_MOUNT_WRITEBACK;
			break;
		case 'L':
			karg.opts.flags |= BDFS_MOUNT_LAZY_LOAD;
			break;
		case 'r':
			karg.opts.flags |= BDFS_MOUNT_RDONLY;
			break;
		case 'u':
			force_userspace = true;
			break;
		case 'h':
			printf(
"Usage: bdfs blend mount --btrfs-uuid <uuid> --dwarfs-uuid <uuid>\n"
"                        --mountpoint <path>\n"
"                        [--compression zstd|lzma|lz4|brotli|none]\n"
"                        [--cache-mb <n>] [--writeback] [--lazy-load]\n"
"                        [--rdonly]\n"
"\n"
"Userspace fallback (fuse-overlayfs) — required when kernel module is absent:\n"
"                        --userspace\n"
"                        --btrfs-mount  <path>  BTRFS upper subvolume\n"
"                        --dwarfs-image <path>  path to .dwarfs image\n"
"                        --work-dir     <path>  overlayfs workdir\n"
			);
			return 0;
		default:
			return 1;
		}
	}

	if (!karg.mount_point[0]) {
		bdfs_err("--mountpoint is required");
		return 1;
	}

	ret = bdfs_cli_open_ctl(cli);
	if (ret) return 1;

	/*
	 * Kernel path: attempt BDFS_IOC_MOUNT_BLEND.
	 * On ENODEV (module not loaded) fall through to the userspace path.
	 * On any other error, report and exit.
	 */
	if (!force_userspace) {
		if (ioctl(cli->ctl_fd, BDFS_IOC_MOUNT_BLEND, &karg) == 0) {
			if (!cli->json_output)
				printf("Blend mount at %s (kernel)\n",
				       karg.mount_point);
			return 0;
		}

		if (errno != ENODEV) {
			bdfs_err("BDFS_IOC_MOUNT_BLEND: %s", strerror(errno));
			return 1;
		}

		/* ENODEV → kernel module absent, fall back to userspace */
		bdfs_info("bdfs_blend kernel module not available "
			  "(ENODEV) — falling back to fuse-overlayfs");
	}

	/*
	 * Userspace path: validate the extra arguments that the kernel path
	 * derives internally but fuse-overlayfs needs explicitly.
	 */
	if (!uarg.btrfs_upper[0]) {
		bdfs_err("--btrfs-mount is required for userspace blend mount");
		return 1;
	}
	if (!uarg.dwarfs_image[0]) {
		bdfs_err("--dwarfs-image is required for userspace blend mount");
		return 1;
	}
	if (!uarg.work_dir[0]) {
		bdfs_err("--work-dir is required for userspace blend mount");
		return 1;
	}

	uarg.flags |= BDFS_MOUNT_USERSPACE_OVERLAY;

	if (ioctl(cli->ctl_fd, BDFS_IOC_MOUNT_BLEND_USERSPACE, &uarg) < 0) {
		bdfs_err("BDFS_IOC_MOUNT_BLEND_USERSPACE: %s",
			 strerror(errno));
		return 1;
	}

	if (!cli->json_output)
		printf("Blend mount at %s (fuse-overlayfs)\n",
		       uarg.mount_point);
	return 0;
}

/* ── blend umount ───────────────────────────────────────────────────────── */

int cmd_blend_umount(struct bdfs_cli *cli, int argc, char *argv[])
{
	struct bdfs_ioctl_umount_blend arg;
	int opt, ret;

	static const struct option opts[] = {
		{ "mountpoint", required_argument, NULL, 'm' },
		{ "force",      no_argument,       NULL, 'f' },
		{ "lazy",       no_argument,       NULL, 'l' },
		{ "help",       no_argument,       NULL, 'h' },
		{ NULL, 0, NULL, 0 }
	};

	memset(&arg, 0, sizeof(arg));

	while ((opt = getopt_long(argc, argv, "m:flh", opts, NULL)) != -1) {
		switch (opt) {
		case 'm':
			strncpy(arg.mount_point, optarg,
				sizeof(arg.mount_point) - 1);
			break;
		case 'f':
			arg.flags |= BDFS_UMOUNT_FORCE;
			break;
		case 'l':
			arg.flags |= BDFS_UMOUNT_LAZY;
			break;
		case 'h':
			printf("Usage: bdfs blend umount --mountpoint <path> "
			       "[--force] [--lazy]\n");
			return 0;
		default:
			return 1;
		}
	}

	/* Also accept positional mountpoint */
	if (!arg.mount_point[0] && optind < argc)
		strncpy(arg.mount_point, argv[optind],
			sizeof(arg.mount_point) - 1);

	if (!arg.mount_point[0]) {
		bdfs_err("--mountpoint is required");
		return 1;
	}

	ret = bdfs_cli_open_ctl(cli);
	if (ret) return 1;

	if (ioctl(cli->ctl_fd, BDFS_IOC_UMOUNT_BLEND, &arg) < 0) {
		bdfs_err("BDFS_IOC_UMOUNT_BLEND: %s", strerror(errno));
		return 1;
	}

	if (!cli->json_output)
		printf("Blend unmounted: %s\n", arg.mount_point);
	return 0;
}
