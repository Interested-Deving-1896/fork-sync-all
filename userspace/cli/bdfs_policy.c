// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * bdfs_policy.c (CLI) - policy subcommands
 *
 *   bdfs policy add    --partition <uuid> --age-days <n>
 *                      [--compression zstd|lzma|lz4|brotli|none]
 *                      [--name-pattern <glob>]
 *                      [--min-size-mb <n>]
 *                      [--readonly]
 *                      [--delete-after-demote]
 *
 *   bdfs policy remove <rule-id>
 *
 *   bdfs policy list   [--partition <uuid>]
 *
 *   bdfs policy scan   [--partition <uuid>]   (trigger immediate scan)
 *
 * Policy rules are sent to the daemon via the Unix socket using the
 * JSON protocol.  The daemon's policy engine applies them on the next
 * scheduled scan (default: every hour) or immediately on `policy scan`.
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <getopt.h>
#include <errno.h>
#include <sys/socket.h>
#include <sys/un.h>

#include "bdfs.h"

/* Send a JSON request to the daemon socket and print the response */
static int daemon_request(struct bdfs_cli *cli,
			  const char *json_req)
{
	struct sockaddr_un addr;
	int fd, ret = 0;
	char resp[4096] = {0};
	ssize_t n;

	fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
	if (fd < 0) {
		bdfs_err("socket: %s", strerror(errno));
		return -errno;
	}

	memset(&addr, 0, sizeof(addr));
	addr.sun_family = AF_UNIX;
	strncpy(addr.sun_path, cli->socket_path, sizeof(addr.sun_path) - 1);

	if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		bdfs_err("cannot connect to daemon at %s: %s",
			 cli->socket_path, strerror(errno));
		close(fd);
		return -errno;
	}

	if (send(fd, json_req, strlen(json_req), MSG_NOSIGNAL) < 0) {
		bdfs_err("send: %s", strerror(errno));
		close(fd);
		return -errno;
	}

	n = recv(fd, resp, sizeof(resp) - 1, 0);
	if (n > 0) {
		resp[n] = '\0';
		if (cli->json_output)
			printf("%s", resp);
		else {
			/* Extract status field for human output */
			if (strstr(resp, "\"status\":0"))
				printf("OK\n");
			else
				printf("Response: %s\n", resp);
		}
	}

	close(fd);
	return ret;
}

/* ── policy add ─────────────────────────────────────────────────────────── */

int cmd_policy_add(struct bdfs_cli *cli, int argc, char *argv[])
{
	char partition_uuid_str[37] = {0};
	uint8_t partition_uuid[16] = {0};
	uint32_t age_days = 0;
	uint32_t compression = BDFS_COMPRESS_ZSTD;
	char name_pattern[256] = {0};
	uint64_t min_size_mb = 0;
	bool readonly = false;
	bool delete_after = false;
	int opt;
	char req[1024];

	static const struct option opts[] = {
		{ "partition",         required_argument, NULL, 'p' },
		{ "age-days",          required_argument, NULL, 'a' },
		{ "compression",       required_argument, NULL, 'c' },
		{ "name-pattern",      required_argument, NULL, 'n' },
		{ "min-size-mb",       required_argument, NULL, 'm' },
		{ "readonly",          no_argument,       NULL, 'r' },
		{ "delete-after-demote", no_argument,     NULL, 'd' },
		{ "help",              no_argument,       NULL, 'h' },
		{ NULL, 0, NULL, 0 }
	};

	while ((opt = getopt_long(argc, argv, "p:a:c:n:m:rdh",
				  opts, NULL)) != -1) {
		switch (opt) {
		case 'p':
			if (bdfs_str_to_uuid(optarg, partition_uuid) < 0) {
				bdfs_err("invalid UUID: %s", optarg);
				return 1;
			}
			strncpy(partition_uuid_str, optarg,
				sizeof(partition_uuid_str) - 1);
			break;
		case 'a': age_days    = (uint32_t)atoi(optarg); break;
		case 'c': compression = bdfs_compression_from_name(optarg); break;
		case 'n': strncpy(name_pattern, optarg,
				  sizeof(name_pattern) - 1); break;
		case 'm': min_size_mb = (uint64_t)strtoull(optarg, NULL, 0); break;
		case 'r': readonly     = true; break;
		case 'd': delete_after = true; break;
		case 'h':
			printf(
"Usage: bdfs policy add --partition <uuid> --age-days <n> [OPTIONS]\n"
"\n"
"  --compression <algo>     Compression for demoted images (default: zstd)\n"
"  --name-pattern <glob>    Only demote subvolumes matching this pattern\n"
"  --min-size-mb <n>        Only demote subvolumes >= N MiB\n"
"  --readonly               Make imported subvolume read-only\n"
"  --delete-after-demote    Remove BTRFS subvolume after image is created\n"
			);
			return 0;
		default: return 1;
		}
	}

	if (!partition_uuid_str[0]) { bdfs_err("--partition is required"); return 1; }
	if (!age_days)              { bdfs_err("--age-days is required");   return 1; }

	snprintf(req, sizeof(req),
		 "{\"cmd\":\"policy-add\","
		 "\"args\":{"
		 "\"partition\":\"%s\","
		 "\"age_days\":%u,"
		 "\"compression\":\"%s\","
		 "\"name_pattern\":\"%s\","
		 "\"min_size_bytes\":%llu,"
		 "\"readonly\":%s,"
		 "\"delete_after_demote\":%s"
		 "}}\n",
		 partition_uuid_str,
		 age_days,
		 bdfs_compression_name(compression),
		 name_pattern,
		 (unsigned long long)(min_size_mb * 1024 * 1024),
		 readonly     ? "true" : "false",
		 delete_after ? "true" : "false");

	return daemon_request(cli, req);
}

/* ── policy remove ──────────────────────────────────────────────────────── */

int cmd_policy_remove(struct bdfs_cli *cli, int argc, char *argv[])
{
	char req[256];

	if (argc < 2) {
		bdfs_err("Usage: bdfs policy remove <rule-id>");
		return 1;
	}

	snprintf(req, sizeof(req),
		 "{\"cmd\":\"policy-remove\",\"args\":{\"rule_id\":%s}}\n",
		 argv[1]);

	return daemon_request(cli, req);
}

/* ── policy list ────────────────────────────────────────────────────────── */

int cmd_policy_list(struct bdfs_cli *cli, int argc, char *argv[])
{
	char req[256];
	(void)argc; (void)argv;

	snprintf(req, sizeof(req),
		 "{\"cmd\":\"policy-list\"}\n");

	return daemon_request(cli, req);
}

/* ── policy scan ────────────────────────────────────────────────────────── */

int cmd_policy_scan(struct bdfs_cli *cli, int argc, char *argv[])
{
	char req[256];
	(void)argc; (void)argv;

	if (!cli->json_output)
		printf("Triggering immediate policy scan...\n");

	snprintf(req, sizeof(req),
		 "{\"cmd\":\"policy-scan\"}\n");

	return daemon_request(cli, req);
}
