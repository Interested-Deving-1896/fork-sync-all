// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * bdfs_main.c - bdfs CLI entry point
 *
 * Usage:
 *   bdfs [global-opts] <command> [command-opts] [args...]
 *
 * Global options:
 *   -v, --verbose    Verbose output
 *   -j, --json       JSON output
 *   -s, --socket     Daemon socket path (default: /run/bdfs/daemon.sock)
 *   -h, --help       Show help
 *       --version    Show version
 */
#define _GNU_SOURCE
#include <errno.h>
#include <getopt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "bdfs.h"

/* ── Forward declarations ────────────────────────────────────────────────── */

int cmd_partition(struct bdfs_cli *cli, int argc, char *argv[]);
int cmd_export(struct bdfs_cli *cli, int argc, char *argv[]);
int cmd_import(struct bdfs_cli *cli, int argc, char *argv[]);
int cmd_mount(struct bdfs_cli *cli, int argc, char *argv[]);
int cmd_umount(struct bdfs_cli *cli, int argc, char *argv[]);
int cmd_blend_mount(struct bdfs_cli *cli, int argc, char *argv[]);
int cmd_blend_umount(struct bdfs_cli *cli, int argc, char *argv[]);
int cmd_snapshot(struct bdfs_cli *cli, int argc, char *argv[]);
int cmd_promote(struct bdfs_cli *cli, int argc, char *argv[]);
int cmd_demote(struct bdfs_cli *cli, int argc, char *argv[]);
int cmd_fetch(struct bdfs_cli *cli, int argc, char *argv[]);
int cmd_status(struct bdfs_cli *cli, int argc, char *argv[]);
int cmd_verify(struct bdfs_cli *cli, int argc, char *argv[]);
int cmd_setup(struct bdfs_cli *cli, int argc, char *argv[]);
int cmd_home(struct bdfs_cli *cli, int argc, char *argv[]);
int cmd_autosnap(struct bdfs_cli *cli, int argc, char *argv[]);
int cmd_workspace_shutdown(struct bdfs_cli *cli, int argc, char *argv[]);

/* ── Command table ───────────────────────────────────────────────────────── */

struct bdfs_command {
	const char *name;
	const char *alias;   /* optional short alias, NULL if none */
	int (*fn)(struct bdfs_cli *cli, int argc, char *argv[]);
	const char *summary;
};

static const struct bdfs_command COMMANDS[] = {
	{ "partition", "part",   cmd_partition,
	  "Register, unregister, and list BTRFS/DwarFS partitions" },
	{ "export",    NULL,     cmd_export,
	  "Export a BTRFS subvolume to a DwarFS image" },
	{ "import",    NULL,     cmd_import,
	  "Import a DwarFS image into a BTRFS subvolume" },
	{ "mount",     NULL,     cmd_mount,
	  "Mount a DwarFS image" },
	{ "umount",    "unmount", cmd_umount,
	  "Unmount a DwarFS image" },
	{ "snapshot",  "snap",   cmd_snapshot,
	  "Create or delete BTRFS snapshots" },
	{ "promote",   NULL,     cmd_promote,
	  "Promote a DwarFS-backed path to a writable BTRFS subvolume" },
	{ "demote",    NULL,     cmd_demote,
	  "Demote a BTRFS subvolume to a compressed DwarFS image" },
	{ "status",    "st",     cmd_status,
	  "Show registered partitions, mounts, and job queue" },
	{ "verify",    NULL,     cmd_verify,
	  "Verify a DwarFS image (checksum + dwarfsck)" },
	{ "setup",     NULL,     cmd_setup,
	  "Setup utilities: fstab generation, dependency check" },
	{ "home",      NULL,     cmd_home,
	  "Home directory subvolume init, snapshots, and DwarFS archival" },
	{ "autosnap",  NULL,     cmd_autosnap,
	  "Manage package-manager snapshots (list, delete, rollback, status, prune)" },
	{ "workspace-shutdown", NULL, cmd_workspace_shutdown,
	  "Send workspace lifecycle hook to daemon (pause|delete|stop)" },
	{ "fetch",     NULL,     cmd_fetch,
	  "Restore a workspace snapshot from an IPFS CID" },
};

/* blend is a sub-namespace: `bdfs blend mount` / `bdfs blend umount` */
static int cmd_blend(struct bdfs_cli *cli, int argc, char *argv[])
{
	if (argc < 1) {
		fprintf(stderr,
			"Usage: bdfs blend <mount|umount> [options]\n"
			"\n"
			"  mount    Mount the blend layer (kernel or fuse-overlayfs)\n"
			"  umount   Unmount the blend layer\n"
			"\n"
			"Run 'bdfs blend <subcommand> --help' for details.\n");
		return 1;
	}

	if (strcmp(argv[0], "mount") == 0)
		return cmd_blend_mount(cli, argc - 1, argv + 1);
	if (strcmp(argv[0], "umount") == 0 ||
	    strcmp(argv[0], "unmount") == 0)
		return cmd_blend_umount(cli, argc - 1, argv + 1);

	bdfs_err("unknown blend subcommand: %s", argv[0]);
	return 1;
}

/* ── Global help ─────────────────────────────────────────────────────────── */

static void print_usage(void)
{
	printf(
"Usage: bdfs [OPTIONS] <command> [command-options]\n"
"\n"
"Global options:\n"
"  -v, --verbose          Verbose output\n"
"  -j, --json             JSON output\n"
"  -s, --socket <path>    Daemon socket (default: /run/bdfs/daemon.sock)\n"
"  -h, --help             Show this help\n"
"      --version          Show version\n"
"\n"
"Commands:\n"
	);

	for (size_t i = 0; i < sizeof(COMMANDS) / sizeof(COMMANDS[0]); i++) {
		const struct bdfs_command *c = &COMMANDS[i];
		if (c->alias)
			printf("  %-14s (%-6s)  %s\n",
			       c->name, c->alias, c->summary);
		else
			printf("  %-22s  %s\n", c->name, c->summary);
	}

	printf("  %-22s  %s\n", "blend mount",
	       "Mount the blend layer (kernel or fuse-overlayfs fallback)");
	printf("  %-22s  %s\n", "blend umount",
	       "Unmount the blend layer");
	printf("\n"
	       "Run 'bdfs <command> --help' for command-specific options.\n"
	       "Run 'bdfs autosnap --help' for package-manager snapshot management.\n");
}

/* ── Entry point ─────────────────────────────────────────────────────────── */

int main(int argc, char *argv[])
{
	struct bdfs_cli cli;
	int opt;

	static const struct option global_opts[] = {
		{ "verbose", no_argument,       NULL, 'v' },
		{ "json",    no_argument,       NULL, 'j' },
		{ "socket",  required_argument, NULL, 's' },
		{ "help",    no_argument,       NULL, 'h' },
		{ "version", no_argument,       NULL, 'V' },
		{ NULL, 0, NULL, 0 }
	};

	bdfs_cli_init(&cli);

	/* Parse global options — stop at first non-option (the command name) */
	while ((opt = getopt_long(argc, argv, "+vjs:hV",
				  global_opts, NULL)) != -1) {
		switch (opt) {
		case 'v': cli.verbose     = true;   break;
		case 'j': cli.json_output = true;   break;
		case 's':
			strncpy(cli.socket_path, optarg,
				sizeof(cli.socket_path) - 1);
			break;
		case 'h':
			print_usage();
			return 0;
		case 'V':
			printf("bdfs %s\n", BDFS_VERSION);
			return 0;
		default:
			print_usage();
			return 1;
		}
	}

	if (optind >= argc) {
		print_usage();
		return 1;
	}

	const char *cmd_name = argv[optind];
	int cmd_argc = argc - optind - 1;
	char **cmd_argv = argv + optind + 1;

	/* blend is a special two-level namespace */
	if (strcmp(cmd_name, "blend") == 0)
		return cmd_blend(&cli, cmd_argc, cmd_argv);

	/* Look up in the command table */
	for (size_t i = 0; i < sizeof(COMMANDS) / sizeof(COMMANDS[0]); i++) {
		const struct bdfs_command *c = &COMMANDS[i];
		if (strcmp(cmd_name, c->name) == 0 ||
		    (c->alias && strcmp(cmd_name, c->alias) == 0)) {
			int ret = c->fn(&cli, cmd_argc, cmd_argv);
			bdfs_cli_cleanup(&cli);
			return ret;
		}
	}

	bdfs_err("unknown command: %s", cmd_name);
	fprintf(stderr, "Run 'bdfs --help' for available commands.\n");
	bdfs_cli_cleanup(&cli);
	return 1;
}
