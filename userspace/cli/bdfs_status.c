// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * bdfs_status.c - status subcommand
 *
 *   bdfs status  [--partition <uuid>]
 *
 * Without --partition: shows all registered partitions, their image/subvol
 * counts, and daemon health via the unix socket.
 *
 * With --partition: shows full details for that partition including all
 * DwarFS images (for dwarfs-backed) or all subvolumes (for btrfs-backed).
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <getopt.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/un.h>

#include "bdfs.h"

/* Query the daemon socket for a status ping */
static int query_daemon_status(struct bdfs_cli *cli,
				char *buf, size_t bufsz)
{
	struct sockaddr_un addr;
	int fd, ret = -1;
	ssize_t n;
	const char *req = "{\"cmd\":\"status\"}\n";

	fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
	if (fd < 0)
		return -errno;

	memset(&addr, 0, sizeof(addr));
	addr.sun_family = AF_UNIX;
	strncpy(addr.sun_path, cli->socket_path, sizeof(addr.sun_path) - 1);

	if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0)
		goto out;

	if (send(fd, req, strlen(req), MSG_NOSIGNAL) < 0)
		goto out;

	n = recv(fd, buf, bufsz - 1, 0);
	if (n > 0) {
		buf[n] = '\0';
		ret = 0;
	}

out:
	close(fd);
	return ret;
}

/* Print DwarFS images for a dwarfs-backed partition */
static void print_dwarfs_images(struct bdfs_cli *cli,
				const uint8_t part_uuid[16],
				bool json)
{
	struct bdfs_ioctl_list_dwarfs_images arg;
	struct bdfs_dwarfs_image *buf;
	uint32_t i, cap = 64;

	buf = calloc(cap, sizeof(*buf));
	if (!buf) return;

	memset(&arg, 0, sizeof(arg));
	memcpy(arg.partition_uuid, part_uuid, 16);
	arg.count  = cap;
	arg.images = buf;

	if (ioctl(cli->ctl_fd, BDFS_IOC_LIST_DWARFS_IMAGES, &arg) < 0)
		goto out;

	if (arg.total > cap) {
		free(buf);
		cap = arg.total;
		buf = calloc(cap, sizeof(*buf));
		if (!buf) return;
		arg.count  = cap;
		arg.images = buf;
		if (ioctl(cli->ctl_fd, BDFS_IOC_LIST_DWARFS_IMAGES, &arg) < 0)
			goto out;
	}

	if (json) {
		printf("\"images\":[");
		for (i = 0; i < arg.count; i++) {
			if (i) printf(",");
			bdfs_print_image(&buf[i], true);
		}
		printf("]");
	} else {
		printf("  DwarFS images (%u):\n", arg.count);
		for (i = 0; i < arg.count; i++) {
			printf("  [%llu] %s\n",
			       (unsigned long long)buf[i].image_id,
			       buf[i].name);
			bdfs_print_image(&buf[i], false);
			printf("\n");
		}
	}

out:
	free(buf);
}

/* Print BTRFS subvolumes for a btrfs-backed partition */
static void print_btrfs_subvols(struct bdfs_cli *cli,
				const uint8_t part_uuid[16],
				bool json)
{
	struct bdfs_ioctl_list_btrfs_subvols arg;
	struct bdfs_btrfs_subvol *buf;
	uint32_t i, cap = 64;

	buf = calloc(cap, sizeof(*buf));
	if (!buf) return;

	memset(&arg, 0, sizeof(arg));
	memcpy(arg.partition_uuid, part_uuid, 16);
	arg.count   = cap;
	arg.subvols = buf;

	if (ioctl(cli->ctl_fd, BDFS_IOC_LIST_BTRFS_SUBVOLS, &arg) < 0)
		goto out;

	if (arg.total > cap) {
		free(buf);
		cap = arg.total;
		buf = calloc(cap, sizeof(*buf));
		if (!buf) return;
		arg.count   = cap;
		arg.subvols = buf;
		if (ioctl(cli->ctl_fd, BDFS_IOC_LIST_BTRFS_SUBVOLS, &arg) < 0)
			goto out;
	}

	if (json) {
		printf("\"subvols\":[");
		for (i = 0; i < arg.count; i++) {
			if (i) printf(",");
			bdfs_print_subvol(&buf[i], true);
		}
		printf("]");
	} else {
		printf("  BTRFS subvolumes/snapshots (%u):\n", arg.count);
		for (i = 0; i < arg.count; i++) {
			printf("  [%llu] %s%s\n",
			       (unsigned long long)buf[i].subvol_id,
			       buf[i].name,
			       buf[i].is_snapshot ? " (snapshot)" : "");
			bdfs_print_subvol(&buf[i], false);
			printf("\n");
		}
	}

out:
	free(buf);
}

/* ── status ─────────────────────────────────────────────────────────────── */

int cmd_status(struct bdfs_cli *cli, int argc, char *argv[])
{
	struct bdfs_ioctl_list_partitions list_arg;
	struct bdfs_partition *parts = NULL;
	uint8_t filter_uuid[16];
	bool has_filter = false;
	char daemon_status[512] = "(not running)";
	uint32_t i, cap = 64;
	int opt, ret;

	static const struct option opts[] = {
		{ "partition", required_argument, NULL, 'p' },
		{ "help",      no_argument,       NULL, 'h' },
		{ NULL, 0, NULL, 0 }
	};

	while ((opt = getopt_long(argc, argv, "p:h", opts, NULL)) != -1) {
		switch (opt) {
		case 'p':
			if (bdfs_str_to_uuid(optarg, filter_uuid) < 0) {
				bdfs_err("invalid UUID: %s", optarg);
				return 1;
			}
			has_filter = true;
			break;
		case 'h':
			printf("Usage: bdfs status [--partition <uuid>]\n");
			return 0;
		default: return 1;
		}
	}

	ret = bdfs_cli_open_ctl(cli);
	if (ret) return 1;

	/* Query daemon health */
	query_daemon_status(cli, daemon_status, sizeof(daemon_status));

	/* Fetch partition list */
	parts = calloc(cap, sizeof(*parts));
	if (!parts) { bdfs_err("out of memory"); return 1; }

	memset(&list_arg, 0, sizeof(list_arg));
	list_arg.count = cap;
	list_arg.parts = parts;

	if (ioctl(cli->ctl_fd, BDFS_IOC_LIST_PARTITIONS, &list_arg) < 0) {
		bdfs_err("BDFS_IOC_LIST_PARTITIONS: %s", strerror(errno));
		free(parts);
		return 1;
	}

	if (list_arg.total > cap) {
		free(parts);
		cap = list_arg.total;
		parts = calloc(cap, sizeof(*parts));
		if (!parts) { bdfs_err("out of memory"); return 1; }
		list_arg.count = cap;
		list_arg.parts = parts;
		ioctl(cli->ctl_fd, BDFS_IOC_LIST_PARTITIONS, &list_arg);
	}

	if (cli->json_output) {
		printf("{\"daemon\":%s,\"partitions\":[", daemon_status);
		for (i = 0; i < list_arg.count; i++) {
			struct bdfs_partition *p = &parts[i];
			char uuid[37];
			if (has_filter && memcmp(p->uuid, filter_uuid, 16))
				continue;
			if (i) printf(",");
			bdfs_uuid_to_str(p->uuid, uuid);
			printf("{\"uuid\":\"%s\"", uuid);
			if (p->type == BDFS_PART_DWARFS_BACKED) {
				printf(",");
				print_dwarfs_images(cli, p->uuid, true);
			} else if (p->type == BDFS_PART_BTRFS_BACKED) {
				printf(",");
				print_btrfs_subvols(cli, p->uuid, true);
			}
			printf("}");
		}
		printf("]}\n");
	} else {
		printf("BTRFS+DwarFS Framework Status\n");
		printf("==============================\n");
		printf("Daemon:     %s\n\n", daemon_status);
		printf("Partitions: %u registered\n\n", list_arg.count);

		for (i = 0; i < list_arg.count; i++) {
			struct bdfs_partition *p = &parts[i];
			char uuid[37];
			if (has_filter && memcmp(p->uuid, filter_uuid, 16))
				continue;
			bdfs_uuid_to_str(p->uuid, uuid);
			printf("[%s]\n", uuid);
			bdfs_print_partition(p, false);

			if (p->type == BDFS_PART_DWARFS_BACKED)
				print_dwarfs_images(cli, p->uuid, false);
			else if (p->type == BDFS_PART_BTRFS_BACKED)
				print_btrfs_subvols(cli, p->uuid, false);
			printf("\n");
		}
	}

	free(parts);
	return 0;
}
