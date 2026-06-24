// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * bdfs_partition.c - partition subcommands
 *
 *   bdfs partition add    --type <dwarfs-backed|btrfs-backed|hybrid-blend>
 *                         --device <path> --label <label>
 *                         [--mount <mountpoint>]
 *
 *   bdfs partition remove <uuid>
 *
 *   bdfs partition list   [--type <type>]
 *
 *   bdfs partition show   <uuid>
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

/* ── partition add ──────────────────────────────────────────────────────── */

int cmd_partition_add(struct bdfs_cli *cli, int argc, char *argv[])
{
	struct bdfs_ioctl_register_partition arg;
	char uuid_out[37];
	const char *type_str = NULL;
	int opt, ret;

	static const struct option opts[] = {
		{ "type",   required_argument, NULL, 't' },
		{ "device", required_argument, NULL, 'd' },
		{ "label",  required_argument, NULL, 'l' },
		{ "mount",  required_argument, NULL, 'm' },
		{ "help",   no_argument,       NULL, 'h' },
		{ NULL, 0, NULL, 0 }
	};

	memset(&arg, 0, sizeof(arg));
	arg.part.magic         = BDFS_MAGIC;
	arg.part.version_major = BDFS_VERSION_MAJOR;
	arg.part.version_minor = BDFS_VERSION_MINOR;

	while ((opt = getopt_long(argc, argv, "t:d:l:m:h", opts, NULL)) != -1) {
		switch (opt) {
		case 't': type_str = optarg; break;
		case 'd':
			strncpy(arg.part.device_path, optarg,
				sizeof(arg.part.device_path) - 1);
			break;
		case 'l':
			strncpy(arg.part.label, optarg,
				sizeof(arg.part.label) - 1);
			break;
		case 'm':
			strncpy(arg.part.mount_point, optarg,
				sizeof(arg.part.mount_point) - 1);
			break;
		case 'h':
			printf("Usage: bdfs partition add --type <type> "
			       "--device <path> --label <label> "
			       "[--mount <mountpoint>]\n"
			       "Types: dwarfs-backed  btrfs-backed  hybrid-blend\n");
			return 0;
		default:
			return 1;
		}
	}

	if (!type_str) { bdfs_err("--type is required"); return 1; }
	if (!arg.part.device_path[0]) { bdfs_err("--device is required"); return 1; }

	if (!strcmp(type_str, "dwarfs-backed"))
		arg.part.type = BDFS_PART_DWARFS_BACKED;
	else if (!strcmp(type_str, "btrfs-backed"))
		arg.part.type = BDFS_PART_BTRFS_BACKED;
	else if (!strcmp(type_str, "hybrid-blend"))
		arg.part.type = BDFS_PART_HYBRID_BLEND;
	else {
		bdfs_err("unknown type '%s' (dwarfs-backed|btrfs-backed|hybrid-blend)",
			 type_str);
		return 1;
	}

	ret = bdfs_cli_open_ctl(cli);
	if (ret) return 1;

	if (ioctl(cli->ctl_fd, BDFS_IOC_REGISTER_PARTITION, &arg) < 0) {
		bdfs_err("BDFS_IOC_REGISTER_PARTITION: %s", strerror(errno));
		return 1;
	}

	bdfs_uuid_to_str(arg.uuid_out, uuid_out);

	if (cli->json_output)
		printf("{\"uuid\":\"%s\"}\n", uuid_out);
	else
		printf("Registered partition %s\n", uuid_out);

	return 0;
}

/* ── partition remove ───────────────────────────────────────────────────── */

int cmd_partition_remove(struct bdfs_cli *cli, int argc, char *argv[])
{
	struct bdfs_ioctl_unregister_partition arg;
	int ret;

	if (argc < 2) { bdfs_err("Usage: bdfs partition remove <uuid>"); return 1; }

	memset(&arg, 0, sizeof(arg));
	if (bdfs_str_to_uuid(argv[1], arg.uuid) < 0) {
		bdfs_err("invalid UUID: %s", argv[1]);
		return 1;
	}

	ret = bdfs_cli_open_ctl(cli);
	if (ret) return 1;

	if (ioctl(cli->ctl_fd, BDFS_IOC_UNREGISTER_PARTITION, &arg) < 0) {
		bdfs_err("BDFS_IOC_UNREGISTER_PARTITION: %s", strerror(errno));
		return 1;
	}

	if (!cli->json_output)
		printf("Removed partition %s\n", argv[1]);
	return 0;
}

/* ── partition list ─────────────────────────────────────────────────────── */

int cmd_partition_list(struct bdfs_cli *cli, int argc, char *argv[])
{
	struct bdfs_ioctl_list_partitions arg;
	struct bdfs_partition *buf = NULL;
	uint32_t i, cap = 64;
	int ret;

	(void)argc; (void)argv;

	ret = bdfs_cli_open_ctl(cli);
	if (ret) return 1;

	/* Two-pass: first get total count, then fetch all */
	buf = calloc(cap, sizeof(*buf));
	if (!buf) { bdfs_err("out of memory"); return 1; }

	memset(&arg, 0, sizeof(arg));
	arg.count = cap;
	arg.parts = buf;

	if (ioctl(cli->ctl_fd, BDFS_IOC_LIST_PARTITIONS, &arg) < 0) {
		bdfs_err("BDFS_IOC_LIST_PARTITIONS: %s", strerror(errno));
		free(buf);
		return 1;
	}

	if (arg.total > cap) {
		free(buf);
		cap = arg.total;
		buf = calloc(cap, sizeof(*buf));
		if (!buf) { bdfs_err("out of memory"); return 1; }
		arg.count = cap;
		arg.parts = buf;
		if (ioctl(cli->ctl_fd, BDFS_IOC_LIST_PARTITIONS, &arg) < 0) {
			bdfs_err("BDFS_IOC_LIST_PARTITIONS: %s", strerror(errno));
			free(buf);
			return 1;
		}
	}

	if (cli->json_output) {
		printf("[");
		for (i = 0; i < arg.count; i++) {
			if (i) printf(",");
			bdfs_print_partition(&buf[i], true);
		}
		printf("]\n");
	} else {
		printf("%u partition(s) registered:\n\n", arg.count);
		for (i = 0; i < arg.count; i++) {
			char uuid[37];
			bdfs_uuid_to_str(buf[i].uuid, uuid);
			printf("[%s]\n", uuid);
			bdfs_print_partition(&buf[i], false);
			printf("\n");
		}
	}

	free(buf);
	return 0;
}

/* ── partition show ─────────────────────────────────────────────────────── */

int cmd_partition_show(struct bdfs_cli *cli, int argc, char *argv[])
{
	struct bdfs_ioctl_list_partitions arg;
	struct bdfs_partition buf[64];
	uint8_t target_uuid[16];
	uint32_t i;
	int ret;

	if (argc < 2) { bdfs_err("Usage: bdfs partition show <uuid>"); return 1; }
	if (bdfs_str_to_uuid(argv[1], target_uuid) < 0) {
		bdfs_err("invalid UUID: %s", argv[1]);
		return 1;
	}

	ret = bdfs_cli_open_ctl(cli);
	if (ret) return 1;

	memset(&arg, 0, sizeof(arg));
	arg.count = 64;
	arg.parts = buf;

	if (ioctl(cli->ctl_fd, BDFS_IOC_LIST_PARTITIONS, &arg) < 0) {
		bdfs_err("BDFS_IOC_LIST_PARTITIONS: %s", strerror(errno));
		return 1;
	}

	for (i = 0; i < arg.count; i++) {
		if (memcmp(buf[i].uuid, target_uuid, 16) == 0) {
			bdfs_print_partition(&buf[i], cli->json_output);
			return 0;
		}
	}

	bdfs_err("partition %s not found", argv[1]);
	return 1;
}
