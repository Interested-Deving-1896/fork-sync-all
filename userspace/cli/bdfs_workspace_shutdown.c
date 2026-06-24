// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * bdfs_workspace_shutdown.c - workspace-shutdown subcommand
 *
 * Sends a BDFS_JOB_WORKSPACE_SHUTDOWN request to the running bdfs_daemon via
 * the Unix domain socket and waits for the daemon to acknowledge completion.
 *
 * Called by bdfs-workspace-shutdown@.service before a workspace container is
 * stopped. The daemon executes the appropriate lifecycle hook (snapshot on
 * pause, mkdwarfs demote on delete, no-op on stop) and responds with a JSON
 * status object.
 *
 * Usage:
 *   bdfs workspace-shutdown --reason pause|delete|stop \
 *                           --workspace-path <path>
 *                           [--compression zstd|lzma|lz4|brotli|none]
 *                           [--prune-keep <n>]
 *                           [--image-path <path>]
 */

#define _GNU_SOURCE
#include <errno.h>
#include <getopt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include "bdfs.h"

/* Maximum response size from the daemon */
#define WS_RESP_MAX 4096

/* Send a workspace-shutdown request over the daemon socket and read reply. */
static int send_workspace_shutdown(struct bdfs_cli *cli,
				   const char *workspace_path,
				   const char *reason,
				   const char *compression,
				   int prune_keep,
				   const char *image_path)
{
	struct sockaddr_un addr;
	int fd, ret = 1;
	char req[BDFS_PATH_MAX * 2 + 256];
	char resp[WS_RESP_MAX];
	ssize_t n;

	fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
	if (fd < 0) {
		bdfs_err("socket: %s", strerror(errno));
		return 1;
	}

	memset(&addr, 0, sizeof(addr));
	addr.sun_family = AF_UNIX;
	strncpy(addr.sun_path, cli->socket_path, sizeof(addr.sun_path) - 1);

	if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		bdfs_err("connect %s: %s", cli->socket_path, strerror(errno));
		goto out;
	}

	/* Build JSON request */
	snprintf(req, sizeof(req),
		 "{\"cmd\":\"workspace_shutdown\","
		 "\"workspace_path\":\"%s\","
		 "\"reason\":\"%s\","
		 "\"compression\":\"%s\","
		 "\"prune_keep\":%d,"
		 "\"image_path\":\"%s\"}\n",
		 workspace_path,
		 reason,
		 compression ? compression : "zstd",
		 prune_keep,
		 image_path ? image_path : "");

	if (send(fd, req, strlen(req), MSG_NOSIGNAL) < 0) {
		bdfs_err("send: %s", strerror(errno));
		goto out;
	}

	/* Read daemon response */
	n = recv(fd, resp, sizeof(resp) - 1, 0);
	if (n > 0) {
		resp[n] = '\0';
		if (cli->verbose || cli->json_output)
			printf("%s\n", resp);
		/* Check for error in response */
		if (strstr(resp, "\"error\""))
			ret = 1;
		else
			ret = 0;
	} else {
		bdfs_err("no response from daemon");
	}

out:
	close(fd);
	return ret;
}

int cmd_workspace_shutdown(struct bdfs_cli *cli, int argc, char *argv[])
{
	char workspace_path[BDFS_PATH_MAX] = "";
	char reason[32]      = "";
	char compression[32] = "zstd";
	char image_path[BDFS_PATH_MAX] = "";
	int  prune_keep = 0;
	int  opt;

	static const struct option opts[] = {
		{ "reason",         required_argument, NULL, 'r' },
		{ "workspace-path", required_argument, NULL, 'w' },
		{ "compression",    required_argument, NULL, 'c' },
		{ "prune-keep",     required_argument, NULL, 'k' },
		{ "image-path",     required_argument, NULL, 'i' },
		{ "help",           no_argument,       NULL, 'h' },
		{ NULL, 0, NULL, 0 }
	};

	while ((opt = getopt_long(argc, argv, "r:w:c:k:i:h",
				  opts, NULL)) != -1) {
		switch (opt) {
		case 'r':
			strncpy(reason, optarg, sizeof(reason) - 1);
			break;
		case 'w':
			strncpy(workspace_path, optarg,
				sizeof(workspace_path) - 1);
			break;
		case 'c':
			strncpy(compression, optarg, sizeof(compression) - 1);
			break;
		case 'k':
			prune_keep = atoi(optarg);
			break;
		case 'i':
			strncpy(image_path, optarg, sizeof(image_path) - 1);
			break;
		case 'h':
			printf(
"Usage: bdfs workspace-shutdown --reason pause|delete|stop\n"
"                               --workspace-path <path>\n"
"                               [--compression zstd|lzma|lz4|brotli|none]\n"
"                               [--prune-keep <n>]\n"
"                               [--image-path <path>]\n"
"\n"
"Send a workspace lifecycle hook to the bdfs daemon before a workspace\n"
"container is stopped.\n"
"\n"
"  --reason pause   Take a read-only BTRFS snapshot of the workspace.\n"
"  --reason delete  Compress the workspace to a DwarFS archive.\n"
"  --reason stop    No-op (workspace stopping normally).\n"
"\n"
"Called automatically by bdfs-workspace-shutdown@.service.\n");
			return 0;
		default:
			return 1;
		}
	}

	if (workspace_path[0] == '\0') {
		bdfs_err("--workspace-path is required");
		return 1;
	}
	if (reason[0] == '\0') {
		bdfs_err("--reason is required (pause|delete|stop)");
		return 1;
	}
	if (strcmp(reason, "pause")  != 0 &&
	    strcmp(reason, "delete") != 0 &&
	    strcmp(reason, "stop")   != 0) {
		bdfs_err("--reason must be pause, delete, or stop");
		return 1;
	}

	/* stop is a local no-op — no need to contact the daemon */
	if (strcmp(reason, "stop") == 0) {
		if (cli->verbose)
			printf("workspace-shutdown: reason=stop, no-op\n");
		return 0;
	}

	return send_workspace_shutdown(cli,
				       workspace_path,
				       reason,
				       compression,
				       prune_keep,
				       image_path);
}
