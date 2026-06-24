// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * bdfs_export_import.c - export and import subcommands
 *
 *   bdfs export --partition <uuid> --subvol-id <id>
 *               --btrfs-mount <path> --name <image-name>
 *               [--compression zstd|lzma|lz4|brotli|none]
 *               [--block-size-bits <n>]  [--workers <n>]
 *               [--incremental --parent-snap <path>]  [--verify]
 *
 *   bdfs import --partition <uuid> --image-id <id>
 *               --btrfs-mount <path> --subvol-name <name>
 *               [--readonly]  [--snapshot]
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <getopt.h>
#include <errno.h>
#include <sys/ioctl.h>

#include "bdfs.h"

/* ── export ─────────────────────────────────────────────────────────────── */

int cmd_export(struct bdfs_cli *cli, int argc, char *argv[])
{
	struct bdfs_ioctl_export_to_dwarfs arg;
	int opt, ret;

	static const struct option opts[] = {
		{ "partition",      required_argument, NULL, 'p' },
		{ "subvol-id",      required_argument, NULL, 'S' },
		{ "btrfs-mount",    required_argument, NULL, 'b' },
		{ "name",           required_argument, NULL, 'n' },
		{ "compression",    required_argument, NULL, 'c' },
		{ "block-size-bits",required_argument, NULL, 'B' },
		{ "workers",        required_argument, NULL, 'w' },
		{ "incremental",    no_argument,       NULL, 'i' },
		{ "parent-snap",    required_argument, NULL, 'P' },
		{ "verify",         no_argument,       NULL, 'V' },
		{ "help",           no_argument,       NULL, 'h' },
		{ NULL, 0, NULL, 0 }
	};

	memset(&arg, 0, sizeof(arg));
	arg.compression    = BDFS_COMPRESS_ZSTD;
	arg.block_size_bits = 22;
	arg.worker_threads  = 4;

	while ((opt = getopt_long(argc, argv, "p:S:b:n:c:B:w:iP:Vh",
				  opts, NULL)) != -1) {
		switch (opt) {
		case 'p':
			if (bdfs_str_to_uuid(optarg, arg.partition_uuid) < 0) {
				bdfs_err("invalid partition UUID: %s", optarg);
				return 1;
			}
			break;
		case 'S': arg.btrfs_subvol_id = (uint64_t)strtoull(optarg, NULL, 0); break;
		case 'b': strncpy(arg.btrfs_mount,      optarg, sizeof(arg.btrfs_mount)      - 1); break;
		case 'n': strncpy(arg.image_name,        optarg, sizeof(arg.image_name)        - 1); break;
		case 'c': arg.compression     = bdfs_compression_from_name(optarg); break;
		case 'B': arg.block_size_bits  = (uint32_t)atoi(optarg); break;
		case 'w': arg.worker_threads   = (uint32_t)atoi(optarg); break;
		case 'i': arg.flags |= BDFS_EXPORT_INCREMENTAL; break;
		case 'P': strncpy(arg.parent_snap_path, optarg, sizeof(arg.parent_snap_path) - 1); break;
		case 'V': arg.flags |= BDFS_EXPORT_VERIFY;      break;
		case 'h':
			printf("Usage: bdfs export --partition <uuid> "
			       "--subvol-id <id> --btrfs-mount <path> "
			       "--name <image-name>\n"
			       "  [--compression zstd|lzma|lz4|brotli|none]\n"
			       "  [--block-size-bits <n>]  [--workers <n>]\n"
			       "  [--incremental --parent-snap <path>]  [--verify]\n");
			return 0;
		default: return 1;
		}
	}

	if (!arg.image_name[0])   { bdfs_err("--name is required");        return 1; }
	if (!arg.btrfs_mount[0])  { bdfs_err("--btrfs-mount is required"); return 1; }
	if ((arg.flags & BDFS_EXPORT_INCREMENTAL) && !arg.parent_snap_path[0]) {
		bdfs_err("--incremental requires --parent-snap <path>");
		return 1;
	}

	ret = bdfs_cli_open_ctl(cli);
	if (ret) return 1;

	if (!cli->json_output)
		printf("Exporting subvol %llu → DwarFS image '%s' "
		       "(compression: %s)...\n",
		       (unsigned long long)arg.btrfs_subvol_id,
		       arg.image_name,
		       bdfs_compression_name(arg.compression));

	if (ioctl(cli->ctl_fd, BDFS_IOC_EXPORT_TO_DWARFS, &arg) < 0) {
		bdfs_err("BDFS_IOC_EXPORT_TO_DWARFS: %s", strerror(errno));
		return 1;
	}

	if (cli->json_output)
		printf("{\"image_id\":%llu}\n",
		       (unsigned long long)arg.image_id_out);
	else
		printf("Export queued. Image ID: %llu\n",
		       (unsigned long long)arg.image_id_out);

	return 0;
}

/* ── import ─────────────────────────────────────────────────────────────── */

int cmd_import(struct bdfs_cli *cli, int argc, char *argv[])
{
	struct bdfs_ioctl_import_from_dwarfs arg;
	int opt, ret;

	static const struct option opts[] = {
		{ "partition",   required_argument, NULL, 'p' },
		{ "image-id",    required_argument, NULL, 'I' },
		{ "btrfs-mount", required_argument, NULL, 'b' },
		{ "subvol-name", required_argument, NULL, 'n' },
		{ "readonly",    no_argument,       NULL, 'r' },
		{ "snapshot",    no_argument,       NULL, 's' },
		{ "help",        no_argument,       NULL, 'h' },
		{ NULL, 0, NULL, 0 }
	};

	memset(&arg, 0, sizeof(arg));

	while ((opt = getopt_long(argc, argv, "p:I:b:n:rsh",
				  opts, NULL)) != -1) {
		switch (opt) {
		case 'p':
			if (bdfs_str_to_uuid(optarg, arg.partition_uuid) < 0) {
				bdfs_err("invalid partition UUID: %s", optarg);
				return 1;
			}
			break;
		case 'I': arg.image_id = (uint64_t)strtoull(optarg, NULL, 0); break;
		case 'b': strncpy(arg.btrfs_mount,  optarg, sizeof(arg.btrfs_mount)  - 1); break;
		case 'n': strncpy(arg.subvol_name,  optarg, sizeof(arg.subvol_name)  - 1); break;
		case 'r': arg.flags |= BDFS_IMPORT_READONLY; break;
		case 's': arg.flags |= BDFS_IMPORT_SNAPSHOT; break;
		case 'h':
			printf("Usage: bdfs import --partition <uuid> "
			       "--image-id <id> --btrfs-mount <path> "
			       "--subvol-name <name>\n"
			       "  [--readonly]  [--snapshot]\n");
			return 0;
		default: return 1;
		}
	}

	if (!arg.subvol_name[0])  { bdfs_err("--subvol-name is required"); return 1; }
	if (!arg.btrfs_mount[0])  { bdfs_err("--btrfs-mount is required"); return 1; }

	ret = bdfs_cli_open_ctl(cli);
	if (ret) return 1;

	if (!cli->json_output)
		printf("Importing DwarFS image %llu → BTRFS subvolume '%s'...\n",
		       (unsigned long long)arg.image_id, arg.subvol_name);

	if (ioctl(cli->ctl_fd, BDFS_IOC_IMPORT_FROM_DWARFS, &arg) < 0) {
		bdfs_err("BDFS_IOC_IMPORT_FROM_DWARFS: %s", strerror(errno));
		return 1;
	}

	if (cli->json_output)
		printf("{\"subvol_id\":%llu}\n",
		       (unsigned long long)arg.subvol_id_out);
	else
		printf("Import queued. Subvolume ID: %llu\n",
		       (unsigned long long)arg.subvol_id_out);

	return 0;
}
