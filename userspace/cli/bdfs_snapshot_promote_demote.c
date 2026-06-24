// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * bdfs_snapshot_promote_demote.c - snapshot, promote, demote, prune subcommands
 *
 * bdfs snapshot --partition <uuid> --subvol-id <id>
 *               --btrfs-mount <path> --name <name>
 *               [--readonly]
 *
 * bdfs promote  --partition <uuid> --blend-path <path>
 *               --subvol-name <name>
 *
 * bdfs demote   --partition <uuid> --blend-path <path>
 *               --image-name <name>
 *               [--compression zstd|lzma|lz4|brotli|none]
 *               [--delete-subvol]
 *
 * bdfs snapshot prune --partition <uuid> --btrfs-mount <path>
 *                     --keep <n>
 *                     [--pattern <glob>]
 *                     [--demote-first] [--compression zstd|...]
 *                     [--dry-run]
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

/* ── bdfs snapshot ───────────────────────────────────────────────────────── */

int cmd_snapshot(struct bdfs_cli *cli, int argc, char *argv[])
{
	/* If first arg is "prune", delegate */
	if (argc > 0 && strcmp(argv[0], "prune") == 0)
		return cmd_snapshot_prune(cli, argc - 1, argv + 1);

	struct bdfs_ioctl_snapshot_dwarfs_container arg;
	int opt;

	static const struct option opts[] = {
		{ "partition",   required_argument, NULL, 'p' },
		{ "subvol-id",   required_argument, NULL, 'i' },
		{ "btrfs-mount", required_argument, NULL, 'm' },
		{ "name",        required_argument, NULL, 'n' },
		{ "readonly",    no_argument,       NULL, 'r' },
		{ "help",        no_argument,       NULL, 'h' },
		{ NULL, 0, NULL, 0 }
	};

	memset(&arg, 0, sizeof(arg));

	while ((opt = getopt_long(argc, argv, "p:i:m:n:rh", opts, NULL)) != -1) {
		switch (opt) {
		case 'p':
			if (bdfs_str_to_uuid(optarg, arg.partition_uuid) < 0) {
				bdfs_err("invalid UUID: %s", optarg);
				return 1;
			}
			break;
		case 'i': arg.image_id = (uint64_t)strtoull(optarg, NULL, 0); break;
		case 'n': strncpy(arg.snapshot_name, optarg,
				  sizeof(arg.snapshot_name) - 1); break;
		case 'r': arg.flags |= BDFS_SNAP_READONLY; break;
		case 'h':
			printf("Usage: bdfs snapshot --partition <uuid> "
			       "--name <name> [--readonly]\n"
			       "       bdfs snapshot prune --partition <uuid> "
			       "--btrfs-mount <path> --keep <n> [OPTIONS]\n");
			return 0;
		default: return 1;
		}
	}

	int ret = bdfs_cli_open_ctl(cli);
	if (ret) return 1;

	if (ioctl(cli->ctl_fd, BDFS_IOC_SNAPSHOT_DWARFS_CONTAINER, &arg) < 0) {
		bdfs_err("BDFS_IOC_SNAPSHOT_DWARFS_CONTAINER: %s",
			 strerror(errno));
		return 1;
	}

	if (!cli->json_output)
		printf("Snapshot '%s' created (subvol id: %llu)\n",
		       arg.snapshot_name,
		       (unsigned long long)arg.snapshot_subvol_id_out);
	else
		printf("{\"status\":0,\"subvol_id\":%llu}\n",
		       (unsigned long long)arg.snapshot_subvol_id_out);
	return 0;
}

/* ── bdfs snapshot prune ─────────────────────────────────────────────────── */

int cmd_snapshot_prune(struct bdfs_cli *cli, int argc, char *argv[])
{
	uint8_t  partition_uuid[16] = {0};
	char     btrfs_mount[BDFS_PATH_MAX] = "";
	char     pattern[256] = "";
	uint32_t keep = 0;
	uint32_t compression = BDFS_COMPRESS_ZSTD;
	uint32_t flags = 0;
	int opt;

	static const struct option opts[] = {
		{ "partition",   required_argument, NULL, 'p' },
		{ "btrfs-mount", required_argument, NULL, 'm' },
		{ "keep",        required_argument, NULL, 'k' },
		{ "pattern",     required_argument, NULL, 'P' },
		{ "demote-first",no_argument,       NULL, 'D' },
		{ "compression", required_argument, NULL, 'c' },
		{ "dry-run",     no_argument,       NULL, 'n' },
		{ "help",        no_argument,       NULL, 'h' },
		{ NULL, 0, NULL, 0 }
	};

	while ((opt = getopt_long(argc, argv, "p:m:k:P:Dc:nh",
				  opts, NULL)) != -1) {
		switch (opt) {
		case 'p':
			if (bdfs_str_to_uuid(optarg, partition_uuid) < 0) {
				bdfs_err("invalid UUID: %s", optarg);
				return 1;
			}
			break;
		case 'm':
			strncpy(btrfs_mount, optarg, sizeof(btrfs_mount) - 1);
			break;
		case 'k':
			keep = (uint32_t)atoi(optarg);
			break;
		case 'P':
			strncpy(pattern, optarg, sizeof(pattern) - 1);
			break;
		case 'D':
			flags |= BDFS_PRUNE_DEMOTE_FIRST;
			break;
		case 'c':
			compression = bdfs_compression_from_name(optarg);
			break;
		case 'n':
			flags |= BDFS_PRUNE_DRY_RUN;
			break;
		case 'h':
			printf(
"Usage: bdfs snapshot prune --partition <uuid> --btrfs-mount <path> --keep <n>\n"
"                           [--pattern <glob>]\n"
"                           [--demote-first [--compression zstd|lzma|lz4|brotli]]\n"
"                           [--dry-run]\n"
"\n"
"  --keep <n>        Number of most-recent snapshots to retain\n"
"  --pattern <glob>  Only consider snapshots matching this name pattern\n"
"  --demote-first    Archive each pruned snapshot as a DwarFS image before deleting\n"
"  --dry-run         Log what would be deleted without making changes\n"
			);
			return 0;
		default: return 1;
		}
	}

	if (!btrfs_mount[0]) {
		bdfs_err("--btrfs-mount is required");
		return 1;
	}
	if (keep == 0) {
		bdfs_err("--keep must be > 0");
		return 1;
	}

	int ret = bdfs_cli_open_ctl(cli);
	if (ret) return 1;

	/*
	 * Send the prune job to the daemon via the Unix socket protocol.
	 * The daemon dispatches BDFS_JOB_PRUNE to the worker pool.
	 */
	char req[1024];
	snprintf(req, sizeof(req),
		 "{\"cmd\":\"prune\","
		 "\"args\":{"
		 "\"btrfs_mount\":\"%s\","
		 "\"pattern\":\"%s\","
		 "\"keep\":%u,"
		 "\"flags\":%u,"
		 "\"compression\":%u"
		 "}}\n",
		 btrfs_mount, pattern, keep, flags, compression);

	char resp[4096] = "";
	ret = bdfs_cli_send_recv(cli, req, resp, sizeof(resp));
	if (ret) {
		bdfs_err("daemon communication failed");
		return 1;
	}

	if (!cli->json_output) {
		if (flags & BDFS_PRUNE_DRY_RUN)
			printf("Prune dry-run queued for %s (keep=%u)\n",
			       btrfs_mount, keep);
		else
			printf("Prune queued for %s (keep=%u%s)\n",
			       btrfs_mount, keep,
			       (flags & BDFS_PRUNE_DEMOTE_FIRST)
				       ? ", demote-first" : "");
	} else {
		printf("%s", resp);
	}

	return 0;
}

/* ── bdfs promote ────────────────────────────────────────────────────────── */

int cmd_promote(struct bdfs_cli *cli, int argc, char *argv[])
{
	struct bdfs_ioctl_promote_to_btrfs arg;
	int opt;

	static const struct option opts[] = {
		{ "partition",  required_argument, NULL, 'p' },
		{ "blend-path", required_argument, NULL, 'b' },
		{ "subvol-name",required_argument, NULL, 'n' },
		{ "help",       no_argument,       NULL, 'h' },
		{ NULL, 0, NULL, 0 }
	};

	memset(&arg, 0, sizeof(arg));

	while ((opt = getopt_long(argc, argv, "p:b:n:h", opts, NULL)) != -1) {
		switch (opt) {
		case 'p':
			if (bdfs_str_to_uuid(optarg, arg.flags /* unused here */
					     ? NULL : NULL) < 0) {
				bdfs_err("invalid UUID: %s", optarg);
				return 1;
			}
			break;
		case 'b':
			strncpy(arg.blend_path, optarg,
				sizeof(arg.blend_path) - 1);
			break;
		case 'n':
			strncpy(arg.subvol_name, optarg,
				sizeof(arg.subvol_name) - 1);
			break;
		case 'h':
			printf("Usage: bdfs promote --blend-path <path> "
			       "--subvol-name <name>\n");
			return 0;
		default: return 1;
		}
	}

	int ret = bdfs_cli_open_ctl(cli);
	if (ret) return 1;

	if (ioctl(cli->ctl_fd, BDFS_IOC_PROMOTE_TO_BTRFS, &arg) < 0) {
		bdfs_err("BDFS_IOC_PROMOTE_TO_BTRFS: %s", strerror(errno));
		return 1;
	}

	if (!cli->json_output)
		printf("Promoted %s → subvol '%s' (id: %llu)\n",
		       arg.blend_path, arg.subvol_name,
		       (unsigned long long)arg.subvol_id_out);
	else
		printf("{\"status\":0,\"subvol_id\":%llu}\n",
		       (unsigned long long)arg.subvol_id_out);
	return 0;
}

/* ── bdfs demote ─────────────────────────────────────────────────────────── */

int cmd_demote(struct bdfs_cli *cli, int argc, char *argv[])
{
	struct bdfs_ioctl_demote_to_dwarfs arg;
	int opt;

	static const struct option opts[] = {
		{ "partition",    required_argument, NULL, 'p' },
		{ "blend-path",   required_argument, NULL, 'b' },
		{ "image-name",   required_argument, NULL, 'n' },
		{ "compression",  required_argument, NULL, 'c' },
		{ "delete-subvol",no_argument,       NULL, 'd' },
		{ "help",         no_argument,       NULL, 'h' },
		{ NULL, 0, NULL, 0 }
	};

	memset(&arg, 0, sizeof(arg));
	arg.compression = BDFS_COMPRESS_ZSTD;

	while ((opt = getopt_long(argc, argv, "p:b:n:c:dh", opts, NULL)) != -1) {
		switch (opt) {
		case 'b':
			strncpy(arg.blend_path, optarg,
				sizeof(arg.blend_path) - 1);
			break;
		case 'n':
			strncpy(arg.image_name, optarg,
				sizeof(arg.image_name) - 1);
			break;
		case 'c':
			arg.compression = bdfs_compression_from_name(optarg);
			break;
		case 'd':
			arg.flags |= BDFS_DEMOTE_DELETE_SUBVOL;
			break;
		case 'h':
			printf("Usage: bdfs demote --blend-path <path> "
			       "--image-name <name>\n"
			       "                   [--compression zstd|lzma|lz4|brotli]\n"
			       "                   [--delete-subvol]\n");
			return 0;
		default: return 1;
		}
	}

	int ret = bdfs_cli_open_ctl(cli);
	if (ret) return 1;

	if (ioctl(cli->ctl_fd, BDFS_IOC_DEMOTE_TO_DWARFS, &arg) < 0) {
		bdfs_err("BDFS_IOC_DEMOTE_TO_DWARFS: %s", strerror(errno));
		return 1;
	}

	if (!cli->json_output)
		printf("Demoted %s → image '%s' (id: %llu)\n",
		       arg.blend_path, arg.image_name,
		       (unsigned long long)arg.image_id_out);
	else
		printf("{\"status\":0,\"image_id\":%llu}\n",
		       (unsigned long long)arg.image_id_out);
	return 0;
}
