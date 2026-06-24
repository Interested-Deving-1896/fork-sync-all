// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * bdfs_autosnap.c - bdfs autosnap subcommand group
 *
 * Provides a first-class `bdfs autosnap` interface for managing the
 * package-manager snapshot hook installed by tools/autosnap/.
 *
 * Subcommands:
 *
 *   bdfs autosnap list   [--partition <uuid>] [--btrfs-mount <path>]
 *     List all autosnap snapshots on a partition.
 *
 *   bdfs autosnap delete --partition <uuid> --btrfs-mount <path> <name>
 *     Delete a single autosnap snapshot by name.
 *
 *   bdfs autosnap rollback --partition <uuid> --btrfs-mount <path> <name>
 *     Roll back to an autosnap snapshot (replaces @ subvolume; reboot needed).
 *
 *   bdfs autosnap status [--partition <uuid>] [--btrfs-mount <path>]
 *                        [<pre-name> [<post-name>]]
 *     Show metadata for one or two snapshots, or list all if no name given.
 *
 *   bdfs autosnap prune  --partition <uuid> --btrfs-mount <path>
 *                        --keep <n>
 *                        [--demote-first] [--compression <algo>] [--dry-run]
 *     Prune autosnap snapshots, keeping the N most recent.
 *     Delegates to bdfs snapshot prune --pattern "autosnap-*".
 *
 * All subcommands that need a partition UUID support auto-detection:
 * if --partition is omitted and exactly one partition is registered,
 * it is used automatically. If multiple partitions exist, --partition
 * is required.
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

#define AUTOSNAP_PATTERN "autosnap-*"
#define AUTOSNAP_PREFIX  "autosnap-"

/* ── Partition auto-detection ────────────────────────────────────────────── */

/*
 * Resolve the partition UUID to use.
 *
 * If uuid_arg is non-empty, validate and return it.
 * Otherwise query the kernel for registered partitions:
 *   - exactly one  → use it, print a notice
 *   - zero         → error
 *   - multiple     → error: require --partition
 *
 * Returns 0 on success, fills uuid_out[16].
 */
static int resolve_partition(struct bdfs_cli *cli,
			     const char *uuid_arg,
			     uint8_t uuid_out[16])
{
	if (uuid_arg && uuid_arg[0]) {
		if (bdfs_str_to_uuid(uuid_arg, uuid_out) < 0) {
			bdfs_err("invalid UUID: %s", uuid_arg);
			return -1;
		}
		return 0;
	}

	/* Auto-detect */
	struct bdfs_ioctl_list_partitions arg;
	struct bdfs_partition buf[128];

	if (bdfs_cli_open_ctl(cli))
		return -1;

	memset(&arg, 0, sizeof(arg));
	arg.count = 128;
	arg.parts = buf;

	if (ioctl(cli->ctl_fd, BDFS_IOC_LIST_PARTITIONS, &arg) < 0) {
		bdfs_err("BDFS_IOC_LIST_PARTITIONS: %s", strerror(errno));
		return -1;
	}

	if (arg.count == 0) {
		bdfs_err("No bdfs partitions registered. "
			 "Use 'bdfs partition add' first.");
		return -1;
	}

	if (arg.count > 1) {
		char uuid_str[37];
		bdfs_err("Multiple partitions registered (%u). "
			 "Specify --partition <uuid>:", arg.count);
		for (uint32_t i = 0; i < arg.count; i++) {
			bdfs_uuid_to_str(buf[i].uuid, uuid_str);
			fprintf(stderr, "  %s  %s\n",
				uuid_str, buf[i].label);
		}
		return -1;
	}

	memcpy(uuid_out, buf[0].uuid, 16);

	char uuid_str[37];
	bdfs_uuid_to_str(uuid_out, uuid_str);
	if (cli->verbose)
		bdfs_info("Auto-selected partition: %s (%s)",
			  uuid_str, buf[0].label);

	return 0;
}

/* ── Snapshot listing helper ─────────────────────────────────────────────── */

/*
 * List btrfs subvolumes under btrfs_mount whose names start with
 * AUTOSNAP_PREFIX, using `btrfs subvolume list -o`.
 * Prints in human or JSON format.
 */
static int list_autosnap_subvols(const char *btrfs_mount, bool json)
{
	char cmd[512];
	snprintf(cmd, sizeof(cmd),
		 "btrfs subvolume list -o '%s' 2>/dev/null"
		 " | awk '$NF ~ /^" AUTOSNAP_PREFIX "/ {print $NF}'",
		 btrfs_mount);

	FILE *fp = popen(cmd, "r");
	if (!fp) {
		bdfs_err("popen: %s", strerror(errno));
		return 1;
	}

	char line[512];
	int count = 0;

	if (json)
		printf("[");

	while (fgets(line, sizeof(line), fp)) {
		/* Strip trailing newline */
		size_t len = strlen(line);
		if (len > 0 && line[len - 1] == '\n')
			line[len - 1] = '\0';

		if (!line[0])
			continue;

		if (json) {
			if (count)
				printf(",");
			printf("{\"name\":\"%s\"}", line);
		} else {
			printf("  %s\n", line);
		}
		count++;
	}

	if (json)
		printf("]\n");
	else if (count == 0)
		printf("  (no autosnap snapshots found)\n");

	pclose(fp);
	return 0;
}

/* ── bdfs autosnap list ──────────────────────────────────────────────────── */

static int cmd_autosnap_list(struct bdfs_cli *cli, int argc, char *argv[])
{
	char uuid_arg[37] = "";
	char btrfs_mount[512] = "/";
	int opt;

	static const struct option opts[] = {
		{ "partition",   required_argument, NULL, 'p' },
		{ "btrfs-mount", required_argument, NULL, 'm' },
		{ "help",        no_argument,       NULL, 'h' },
		{ NULL, 0, NULL, 0 }
	};

	while ((opt = getopt_long(argc, argv, "p:m:h", opts, NULL)) != -1) {
		switch (opt) {
		case 'p': strncpy(uuid_arg,    optarg, sizeof(uuid_arg) - 1);    break;
		case 'm': strncpy(btrfs_mount, optarg, sizeof(btrfs_mount) - 1); break;
		case 'h':
			printf("Usage: bdfs autosnap list "
			       "[--partition <uuid>] [--btrfs-mount <path>]\n");
			return 0;
		default: return 1;
		}
	}

	uint8_t uuid[16];
	if (resolve_partition(cli, uuid_arg, uuid) < 0)
		return 1;

	if (!cli->json_output) {
		char uuid_str[37];
		bdfs_uuid_to_str(uuid, uuid_str);
		printf("autosnap snapshots on %s (partition %s):\n",
		       btrfs_mount, uuid_str);
	}

	return list_autosnap_subvols(btrfs_mount, cli->json_output);
}

/* ── bdfs autosnap delete ────────────────────────────────────────────────── */

static int cmd_autosnap_delete(struct bdfs_cli *cli, int argc, char *argv[])
{
	char uuid_arg[37] = "";
	char btrfs_mount[512] = "/";
	int opt;

	static const struct option opts[] = {
		{ "partition",   required_argument, NULL, 'p' },
		{ "btrfs-mount", required_argument, NULL, 'm' },
		{ "help",        no_argument,       NULL, 'h' },
		{ NULL, 0, NULL, 0 }
	};

	while ((opt = getopt_long(argc, argv, "p:m:h", opts, NULL)) != -1) {
		switch (opt) {
		case 'p': strncpy(uuid_arg,    optarg, sizeof(uuid_arg) - 1);    break;
		case 'm': strncpy(btrfs_mount, optarg, sizeof(btrfs_mount) - 1); break;
		case 'h':
			printf("Usage: bdfs autosnap delete "
			       "[--partition <uuid>] [--btrfs-mount <path>] <name>\n");
			return 0;
		default: return 1;
		}
	}

	if (optind >= argc) {
		bdfs_err("snapshot name required");
		return 1;
	}
	const char *snap_name = argv[optind];

	/* Reject names that don't look like autosnap snapshots */
	if (strncmp(snap_name, AUTOSNAP_PREFIX,
		    strlen(AUTOSNAP_PREFIX)) != 0) {
		bdfs_err("'%s' does not look like an autosnap snapshot "
			 "(expected prefix '" AUTOSNAP_PREFIX "')",
			 snap_name);
		return 1;
	}

	uint8_t uuid[16];
	if (resolve_partition(cli, uuid_arg, uuid) < 0)
		return 1;

	/* Build the full subvolume path and delete it */
	char snap_path[1024];
	snprintf(snap_path, sizeof(snap_path), "%s/%s",
		 btrfs_mount, snap_name);

	if (bdfs_cli_open_ctl(cli))
		return 1;

	struct bdfs_ioctl_snapshot_dwarfs_container del_arg;
	memset(&del_arg, 0, sizeof(del_arg));
	memcpy(del_arg.partition_uuid, uuid, 16);
	strncpy(del_arg.snapshot_name, snap_name,
		sizeof(del_arg.snapshot_name) - 1);
	del_arg.flags |= BDFS_SNAP_DELETE;

	if (ioctl(cli->ctl_fd, BDFS_IOC_SNAPSHOT_DWARFS_CONTAINER,
		  &del_arg) < 0) {
		/*
		 * Fall back to direct btrfs subvolume delete if the ioctl
		 * doesn't support BDFS_SNAP_DELETE yet.
		 */
		char cmd[1024];
		snprintf(cmd, sizeof(cmd),
			 "btrfs subvolume delete '%s' 2>&1", snap_path);
		int rc = system(cmd);
		if (rc != 0) {
			bdfs_err("failed to delete snapshot: %s", snap_path);
			return 1;
		}
	}

	if (!cli->json_output)
		printf("Deleted autosnap snapshot: %s\n", snap_name);
	else
		printf("{\"status\":0,\"deleted\":\"%s\"}\n", snap_name);

	return 0;
}

/* ── bdfs autosnap rollback ──────────────────────────────────────────────── */

static int cmd_autosnap_rollback(struct bdfs_cli *cli, int argc, char *argv[])
{
	char uuid_arg[37] = "";
	char btrfs_mount[512] = "/";
	int opt;

	static const struct option opts[] = {
		{ "partition",   required_argument, NULL, 'p' },
		{ "btrfs-mount", required_argument, NULL, 'm' },
		{ "help",        no_argument,       NULL, 'h' },
		{ NULL, 0, NULL, 0 }
	};

	while ((opt = getopt_long(argc, argv, "p:m:h", opts, NULL)) != -1) {
		switch (opt) {
		case 'p': strncpy(uuid_arg,    optarg, sizeof(uuid_arg) - 1);    break;
		case 'm': strncpy(btrfs_mount, optarg, sizeof(btrfs_mount) - 1); break;
		case 'h':
			printf("Usage: bdfs autosnap rollback "
			       "[--partition <uuid>] [--btrfs-mount <path>] <name>\n"
			       "\n"
			       "Replaces the current @ subvolume with the named snapshot.\n"
			       "The old @ is preserved as @autosnap-rollback-backup-<date>.\n"
			       "A reboot is required for the rollback to take effect.\n");
			return 0;
		default: return 1;
		}
	}

	if (optind >= argc) {
		bdfs_err("snapshot name required");
		return 1;
	}
	const char *snap_name = argv[optind];

	if (strncmp(snap_name, AUTOSNAP_PREFIX,
		    strlen(AUTOSNAP_PREFIX)) != 0) {
		bdfs_err("'%s' does not look like an autosnap snapshot",
			 snap_name);
		return 1;
	}

	uint8_t uuid[16];
	if (resolve_partition(cli, uuid_arg, uuid) < 0)
		return 1;

	/*
	 * Rollback strategy (mirrors the shell backend):
	 *   1. Mount the top-level btrfs volume (subvolid=5).
	 *   2. Rename @ → @autosnap-rollback-backup-<timestamp>.
	 *   3. btrfs subvolume snapshot <snap> @.
	 *   4. Remind the user to reboot.
	 *
	 * We use the bdfs exec helpers (bdfs_exec_btrfs_snapshot) via the
	 * daemon socket so the operation is logged and tracked.
	 */
	fprintf(stderr,
		"bdfs autosnap rollback: rolling back to '%s'\n"
		"  The current @ subvolume will be renamed to "
		"@autosnap-rollback-backup-<date>.\n"
		"  A reboot is required for the rollback to take effect.\n"
		"  Press Ctrl-C within 5 seconds to abort.\n",
		snap_name);
	sleep(5);

	/* Build the rollback request for the daemon */
	char req[1024];
	char uuid_str[37];
	bdfs_uuid_to_str(uuid, uuid_str);

	/* Socket handler reads flat fields (no nested "args" object) */
	snprintf(req, sizeof(req),
		 "{\"cmd\":\"autosnap_rollback\","
		 "\"btrfs_mount\":\"%s\","
		 "\"snapshot_name\":\"%s\"}\n",
		 btrfs_mount, snap_name);

	if (bdfs_cli_open_ctl(cli))
		return 1;

	char resp[4096] = "";
	int ret = bdfs_cli_send_recv(cli, req, resp, sizeof(resp));
	if (ret) {
		bdfs_err("daemon communication failed; "
			 "is bdfs_daemon running?");
		return 1;
	}

	if (!cli->json_output)
		printf("Rollback to '%s' scheduled. Reboot to complete.\n",
		       snap_name);
	else
		printf("%s", resp);

	return 0;
}

/* ── bdfs autosnap status ────────────────────────────────────────────────── */

static int cmd_autosnap_status(struct bdfs_cli *cli, int argc, char *argv[])
{
	char uuid_arg[37] = "";
	char btrfs_mount[512] = "/";
	int opt;

	static const struct option opts[] = {
		{ "partition",   required_argument, NULL, 'p' },
		{ "btrfs-mount", required_argument, NULL, 'm' },
		{ "help",        no_argument,       NULL, 'h' },
		{ NULL, 0, NULL, 0 }
	};

	while ((opt = getopt_long(argc, argv, "p:m:h", opts, NULL)) != -1) {
		switch (opt) {
		case 'p': strncpy(uuid_arg,    optarg, sizeof(uuid_arg) - 1);    break;
		case 'm': strncpy(btrfs_mount, optarg, sizeof(btrfs_mount) - 1); break;
		case 'h':
			printf("Usage: bdfs autosnap status "
			       "[--partition <uuid>] [--btrfs-mount <path>] "
			       "[<pre-name> [<post-name>]]\n"
			       "\n"
			       "With no snapshot names: list all autosnap snapshots.\n"
			       "With one name: show subvolume metadata for that snapshot.\n"
			       "With two names: show btrfs diff between pre and post.\n");
			return 0;
		default: return 1;
		}
	}

	uint8_t uuid[16];
	if (resolve_partition(cli, uuid_arg, uuid) < 0)
		return 1;

	int remaining = argc - optind;

	if (remaining == 0) {
		/* No names: list all */
		return list_autosnap_subvols(btrfs_mount, cli->json_output);
	}

	const char *pre_name  = argv[optind];
	const char *post_name = (remaining >= 2) ? argv[optind + 1] : NULL;

	char pre_path[1024];
	snprintf(pre_path, sizeof(pre_path), "%s/%s", btrfs_mount, pre_name);

	if (post_name) {
		/* Two snapshots: show btrfs diff */
		char post_path[1024];
		snprintf(post_path, sizeof(post_path), "%s/%s",
			 btrfs_mount, post_name);

		char cmd[2048];
		snprintf(cmd, sizeof(cmd),
			 "btrfs subvolume find-new '%s' 9999999 2>/dev/null"
			 " | head -1"
			 " | awk '{print $4}'",
			 pre_path);

		/* Use btrfs send --no-data to get a file-level diff */
		snprintf(cmd, sizeof(cmd),
			 "btrfs send --no-data -p '%s' '%s' 2>/dev/null"
			 " | btrfs receive --dump 2>/dev/null"
			 " | grep -v '^snapshot\\|^subvol'",
			 pre_path, post_path);

		if (!cli->json_output) {
			printf("Changes from %s → %s:\n", pre_name, post_name);
			int rc = system(cmd);
			if (rc != 0)
				printf("  (no changes or diff unavailable)\n");
		} else {
			printf("{\"pre\":\"%s\",\"post\":\"%s\","
			       "\"diff_cmd\":\"%s\"}\n",
			       pre_name, post_name, cmd);
		}
	} else {
		/* One snapshot: show subvolume metadata */
		char cmd[1024];
		snprintf(cmd, sizeof(cmd),
			 "btrfs subvolume show '%s' 2>/dev/null", pre_path);

		if (!cli->json_output) {
			printf("Snapshot: %s\n", pre_name);
			int rc = system(cmd);
			if (rc != 0)
				bdfs_err("snapshot not found: %s", pre_path);
		} else {
			printf("{\"name\":\"%s\",\"path\":\"%s\"}\n",
			       pre_name, pre_path);
		}
	}

	return 0;
}

/* ── bdfs autosnap prune ─────────────────────────────────────────────────── */

static int cmd_autosnap_prune(struct bdfs_cli *cli, int argc, char *argv[])
{
	char uuid_arg[37] = "";
	char btrfs_mount[512] = "/";
	uint32_t keep = 5;
	uint32_t compression = BDFS_COMPRESS_ZSTD;
	uint32_t flags = 0;
	int opt;

	static const struct option opts[] = {
		{ "partition",    required_argument, NULL, 'p' },
		{ "btrfs-mount",  required_argument, NULL, 'm' },
		{ "keep",         required_argument, NULL, 'k' },
		{ "demote-first", no_argument,       NULL, 'D' },
		{ "compression",  required_argument, NULL, 'c' },
		{ "dry-run",      no_argument,       NULL, 'n' },
		{ "help",         no_argument,       NULL, 'h' },
		{ NULL, 0, NULL, 0 }
	};

	while ((opt = getopt_long(argc, argv, "p:m:k:Dc:nh", opts, NULL)) != -1) {
		switch (opt) {
		case 'p': strncpy(uuid_arg,    optarg, sizeof(uuid_arg) - 1);    break;
		case 'm': strncpy(btrfs_mount, optarg, sizeof(btrfs_mount) - 1); break;
		case 'k': keep = (uint32_t)atoi(optarg);                         break;
		case 'D': flags |= BDFS_PRUNE_DEMOTE_FIRST;                      break;
		case 'c': compression = bdfs_compression_from_name(optarg);      break;
		case 'n': flags |= BDFS_PRUNE_DRY_RUN;                           break;
		case 'h':
			printf(
"Usage: bdfs autosnap prune [--partition <uuid>] [--btrfs-mount <path>]\n"
"                           --keep <n>\n"
"                           [--demote-first [--compression <algo>]]\n"
"                           [--dry-run]\n"
"\n"
"Prunes autosnap-* snapshots, keeping the N most recent.\n"
"Delegates to 'bdfs snapshot prune --pattern autosnap-*'.\n"
			);
			return 0;
		default: return 1;
		}
	}

	if (keep == 0) {
		bdfs_err("--keep must be > 0");
		return 1;
	}

	uint8_t uuid[16];
	if (resolve_partition(cli, uuid_arg, uuid) < 0)
		return 1;

	if (bdfs_cli_open_ctl(cli))
		return 1;

	char uuid_str[37];
	bdfs_uuid_to_str(uuid, uuid_str);

	/* Socket handler reads flat fields: "subvol", "pattern", "keep",
	 * "demote_first", "dry_run" — not a nested "args" object. */
	char req[1024];
	snprintf(req, sizeof(req),
		 "{\"cmd\":\"prune\","
		 "\"subvol\":\"%s\","
		 "\"pattern\":\"" AUTOSNAP_PATTERN "\","
		 "\"keep\":%u,"
		 "\"demote_first\":%s,"
		 "\"dry_run\":%s}\n",
		 btrfs_mount, keep,
		 (flags & BDFS_PRUNE_DEMOTE_FIRST) ? "true" : "false",
		 (flags & BDFS_PRUNE_DRY_RUN)      ? "true" : "false");

	char resp[4096] = "";
	int ret = bdfs_cli_send_recv(cli, req, resp, sizeof(resp));
	if (ret) {
		bdfs_err("daemon communication failed");
		return 1;
	}

	if (!cli->json_output) {
		if (flags & BDFS_PRUNE_DRY_RUN)
			printf("Prune dry-run: would keep %u autosnap snapshots "
			       "under %s\n", keep, btrfs_mount);
		else
			printf("Pruned autosnap snapshots under %s (kept %u%s)\n",
			       btrfs_mount, keep,
			       (flags & BDFS_PRUNE_DEMOTE_FIRST)
				       ? ", demote-first" : "");
	} else {
		printf("%s", resp);
	}

	return 0;
}

/* ── bdfs autosnap dispatcher ────────────────────────────────────────────── */

int cmd_autosnap(struct bdfs_cli *cli, int argc, char *argv[])
{
	if (argc < 1) {
		fprintf(stderr,
"Usage: bdfs autosnap <subcommand> [options]\n"
"\n"
"Subcommands:\n"
"  list      List autosnap snapshots\n"
"  delete    Delete an autosnap snapshot\n"
"  rollback  Roll back to an autosnap snapshot\n"
"  status    Show snapshot metadata or diff between two snapshots\n"
"  prune     Prune old autosnap snapshots\n"
"\n"
"All subcommands accept --partition <uuid> and --btrfs-mount <path>.\n"
"If --partition is omitted and exactly one partition is registered,\n"
"it is used automatically.\n"
"\n"
"Run 'bdfs autosnap <subcommand> --help' for details.\n"
		);
		return 1;
	}

	const char *sub = argv[0];
	int sub_argc = argc - 1;
	char **sub_argv = argv + 1;

	if (strcmp(sub, "list")     == 0) return cmd_autosnap_list(cli,     sub_argc, sub_argv);
	if (strcmp(sub, "delete")   == 0) return cmd_autosnap_delete(cli,   sub_argc, sub_argv);
	if (strcmp(sub, "rollback") == 0) return cmd_autosnap_rollback(cli, sub_argc, sub_argv);
	if (strcmp(sub, "status")   == 0) return cmd_autosnap_status(cli,   sub_argc, sub_argv);
	if (strcmp(sub, "prune")    == 0) return cmd_autosnap_prune(cli,    sub_argc, sub_argv);

	bdfs_err("unknown autosnap subcommand: %s", sub);
	fprintf(stderr, "Run 'bdfs autosnap --help' for available subcommands.\n");
	return 1;
}
