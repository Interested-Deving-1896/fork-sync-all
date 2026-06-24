// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * bdfs_home.c - bdfs home subcommand group
 *
 * Manages per-user home directory snapshots on BTRFS, ported and extended
 * from btrfs-home-directory-snapshots.  Supports regular and ecryptfs homes.
 *
 * bdfs home init [--user <name>] [--home <path>]
 *   Convert a home directory to a BTRFS subvolume in-place.
 *
 * bdfs home snapshot [--user <name>] [--name <n>] [--subdir <d>]
 *                    [--delete <n>] [--list] [--json]
 *   Create, delete, or list read-only snapshots of a home directory.
 *   Snapshots are stored in ~/.snapshots/ (or $BDFS_SNAPSHOT_DIR).
 *
 * bdfs home demote [--user <name>] <snapshot-path>
 *   Compress a home snapshot subvolume into a DwarFS archive via the daemon.
 *   Archive is stored in ~/.snapshots/archive/ by default.
 *
 * All subcommands work without the daemon except `demote`, which requires
 * bdfs_daemon to be running (it sends BDFS_IOC_EXPORT_TO_DWARFS).
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <grp.h>
#include <pwd.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "bdfs.h"

/* ── Helpers ─────────────────────────────────────────────────────────────── */

/* Resolve the home directory for a given username or the current user. */
static int resolve_home(const char *user, char *home_out, size_t home_sz,
			char *user_out, size_t user_sz)
{
	struct passwd *pw;

	if (user && user[0]) {
		pw = getpwnam(user);
		if (!pw) {
			bdfs_err("user not found: %s", user);
			return -1;
		}
	} else {
		pw = getpwuid(getuid());
		if (!pw) {
			bdfs_err("cannot determine current user");
			return -1;
		}
	}

	strncpy(home_out, pw->pw_dir, home_sz - 1);
	strncpy(user_out, pw->pw_name, user_sz - 1);
	return 0;
}

/*
 * is_btrfs_subvol - Return true if path is a BTRFS subvolume.
 * A subvolume has inode number 256 on BTRFS.
 */
static bool is_btrfs_subvol(const char *path)
{
	struct stat st;
	if (stat(path, &st) < 0)
		return false;
	return st.st_ino == 256;
}

/*
 * is_btrfs - Return true if path is on a BTRFS filesystem.
 * Uses statfs magic 0x9123683E.
 */
static bool is_btrfs(const char *path)
{
	struct statfs sfs;
	if (statfs(path, &sfs) < 0)
		return false;
	return sfs.f_type == (long)0x9123683EL;
}

/*
 * ecryptfs_private_path - If the home directory is ecryptfs-encrypted,
 * return the path to the .Private directory that should be snapshotted.
 * Returns true and fills private_out if ecryptfs is detected.
 */
static bool ecryptfs_private_path(const char *home, const char *user,
				  char *private_out, size_t sz)
{
	/* ecryptfs stores the encrypted data at /home/.ecryptfs/<user>/.Private */
	char candidate[PATH_MAX];
	char parent[PATH_MAX];

	strncpy(parent, home, sizeof(parent) - 1);
	char *slash = strrchr(parent, '/');
	if (slash)
		*slash = '\0';

	snprintf(candidate, sizeof(candidate),
		 "%s/.ecryptfs/%s/.Private", parent, user);

	if (access(candidate, F_OK) == 0) {
		strncpy(private_out, candidate, sz - 1);
		return true;
	}
	return false;
}

/* Run a command via execvp, wait for it, return exit code. */
static int run_cmd(const char *const argv[])
{
	pid_t pid = fork();
	if (pid < 0) return -errno;
	if (pid == 0) {
		execvp(argv[0], (char *const *)argv);
		_exit(127);
	}
	int status;
	if (waitpid(pid, &status, 0) < 0) return -errno;
	return WIFEXITED(status) ? WEXITSTATUS(status) : -EIO;
}

/* Check whether any process is logged in as uid (via /proc/*/loginuid). */
static bool user_is_logged_in(uid_t uid)
{
	DIR *proc = opendir("/proc");
	if (!proc) return false;

	struct dirent *de;
	bool found = false;
	while ((de = readdir(proc)) != NULL && !found) {
		if (de->d_type != DT_DIR) continue;
		char *end;
		strtol(de->d_name, &end, 10);
		if (*end != '\0') continue; /* not a PID directory */

		char path[64];
		snprintf(path, sizeof(path), "/proc/%s/loginuid", de->d_name);
		FILE *f = fopen(path, "r");
		if (!f) continue;
		unsigned long luid = UINT32_MAX;
		fscanf(f, "%lu", &luid);
		fclose(f);
		if ((uid_t)luid == uid)
			found = true;
	}
	closedir(proc);
	return found;
}

/* ── bdfs home init ──────────────────────────────────────────────────────── */

/*
 * Convert a home directory to a BTRFS subvolume in-place.
 *
 * Algorithm (mirrors home2subvolume):
 *   1. Resolve the target path (ecryptfs .Private or plain home).
 *   2. Verify it is on BTRFS and not already a subvolume.
 *   3. Refuse if the user is currently logged in.
 *   4. Create a new subvolume at <path>.subvol.
 *   5. cp -a --reflink=always <path>/. <path>.subvol/
 *   6. mv <path> <path>.bak && mv <path>.subvol <path>
 *   7. rm -rf <path>.bak
 */
static int cmd_home_init(struct bdfs_cli *cli, int argc, char *argv[])
{
	char user[256] = "";
	char home_override[PATH_MAX] = "";
	int opt;

	static const struct option opts[] = {
		{ "user", required_argument, NULL, 'u' },
		{ "home", required_argument, NULL, 'H' },
		{ "help", no_argument,       NULL, 'h' },
		{ NULL, 0, NULL, 0 }
	};

	while ((opt = getopt_long(argc, argv, "u:H:h", opts, NULL)) != -1) {
		switch (opt) {
		case 'u': strncpy(user, optarg, sizeof(user) - 1); break;
		case 'H': strncpy(home_override, optarg, sizeof(home_override) - 1); break;
		case 'h':
			printf("Usage: bdfs home init [--user <name>] [--home <path>]\n"
			       "Convert a home directory to a BTRFS subvolume.\n");
			return 0;
		default: return 1;
		}
	}

	char home[PATH_MAX], username[256];
	if (home_override[0]) {
		strncpy(home, home_override, sizeof(home) - 1);
		strncpy(username, user[0] ? user : "unknown", sizeof(username) - 1);
	} else {
		if (resolve_home(user[0] ? user : NULL, home, sizeof(home),
				 username, sizeof(username)) < 0)
			return 1;
	}

	/* Determine the actual path to convert (ecryptfs or plain) */
	char target[PATH_MAX];
	bool is_enc = ecryptfs_private_path(home, username, target, sizeof(target));
	if (!is_enc)
		strncpy(target, home, sizeof(target) - 1);

	/* Filesystem checks */
	if (!is_btrfs(target)) {
		bdfs_err("%s is not on a BTRFS filesystem", target);
		return 1;
	}
	if (is_btrfs_subvol(target)) {
		bdfs_err("%s is already a BTRFS subvolume", target);
		return 0; /* idempotent */
	}

	/* Safety: refuse if user is logged in */
	struct passwd *pw = getpwnam(username);
	if (pw && user_is_logged_in(pw->pw_uid)) {
		bdfs_err("user %s is currently logged in — log out first",
			 username);
		return 1;
	}

	if (!cli->json_output)
		printf("Converting %s to a BTRFS subvolume...\n", target);

	/* Create the staging subvolume */
	char staging[PATH_MAX];
	snprintf(staging, sizeof(staging), "%s.subvol", target);

	/* Clean up any leftover staging subvolume */
	if (access(staging, F_OK) == 0) {
		fprintf(stderr, "bdfs home init: removing leftover %s\n", staging);
		if (is_btrfs_subvol(staging)) {
			const char *del[] = { "btrfs", "subvolume", "delete",
					      "-c", staging, NULL };
			run_cmd(del);
		} else {
			const char *rm[] = { "rm", "-rf", staging, NULL };
			run_cmd(rm);
		}
	}

	const char *create[] = { "btrfs", "subvolume", "create", staging, NULL };
	if (run_cmd(create) != 0) {
		bdfs_err("btrfs subvolume create %s failed", staging);
		return 1;
	}

	/* Copy contents with reflinks */
	const char *cp[] = { "cp", "-a", "--reflink=always",
			     /* src */ "", /* dst */ staging, NULL };
	char src[PATH_MAX];
	snprintf(src, sizeof(src), "%s/.", target);
	cp[3] = src;
	if (run_cmd(cp) != 0) {
		bdfs_err("cp failed; reverting");
		const char *del[] = { "btrfs", "subvolume", "delete",
				      "-c", staging, NULL };
		run_cmd(del);
		return 1;
	}

	/* Atomic swap: target → target.bak, staging → target */
	char backup[PATH_MAX];
	snprintf(backup, sizeof(backup), "%s.bak", target);

	if (rename(target, backup) < 0) {
		bdfs_err("rename %s → %s: %s", target, backup, strerror(errno));
		const char *del[] = { "btrfs", "subvolume", "delete",
				      "-c", staging, NULL };
		run_cmd(del);
		return 1;
	}
	if (rename(staging, target) < 0) {
		bdfs_err("rename %s → %s: %s", staging, target, strerror(errno));
		rename(backup, target); /* best-effort revert */
		return 1;
	}

	/* Remove the backup */
	const char *rm[] = { "rm", "-rf", backup, NULL };
	run_cmd(rm);

	if (!cli->json_output)
		printf("Converted %s to a BTRFS subvolume.\n", target);
	else
		printf("{\"status\":0,\"path\":\"%s\"}\n", target);

	return 0;
}

/* ── bdfs home snapshot ──────────────────────────────────────────────────── */

static int cmd_home_snapshot(struct bdfs_cli *cli, int argc, char *argv[])
{
	char user[256] = "";
	char snap_name[256] = "";
	char subdir[256] = "";
	char delete_name[256] = "";
	bool do_list = false;
	int opt;

	static const struct option opts[] = {
		{ "user",   required_argument, NULL, 'u' },
		{ "name",   required_argument, NULL, 'n' },
		{ "subdir", required_argument, NULL, 's' },
		{ "delete", required_argument, NULL, 'd' },
		{ "list",   no_argument,       NULL, 'l' },
		{ "help",   no_argument,       NULL, 'h' },
		{ NULL, 0, NULL, 0 }
	};

	while ((opt = getopt_long(argc, argv, "u:n:s:d:lh", opts, NULL)) != -1) {
		switch (opt) {
		case 'u': strncpy(user,        optarg, sizeof(user) - 1);        break;
		case 'n': strncpy(snap_name,   optarg, sizeof(snap_name) - 1);   break;
		case 's': strncpy(subdir,      optarg, sizeof(subdir) - 1);      break;
		case 'd': strncpy(delete_name, optarg, sizeof(delete_name) - 1); break;
		case 'l': do_list = true; break;
		case 'h':
			printf(
"Usage: bdfs home snapshot [OPTIONS]\n"
"  --user <name>    Target user (default: current user)\n"
"  --name <n>       Snapshot name (default: timestamp)\n"
"  --subdir <d>     Store snapshot in ~/.snapshots/<d>/\n"
"  --delete <n>     Delete named snapshot\n"
"  --list           List existing snapshots\n"
			);
			return 0;
		default: return 1;
		}
	}

	char home[PATH_MAX], username[256];
	if (resolve_home(user[0] ? user : NULL, home, sizeof(home),
			 username, sizeof(username)) < 0)
		return 1;

	/* Determine snapshot root from env or default */
	const char *snap_env = getenv("BDFS_SNAPSHOT_DIR");
	char snap_root[PATH_MAX];
	if (snap_env && snap_env[0])
		strncpy(snap_root, snap_env, sizeof(snap_root) - 1);
	else
		snprintf(snap_root, sizeof(snap_root), "%s/.snapshots", home);

	/* Determine the actual subvolume to snapshot */
	char target[PATH_MAX];
	bool is_enc = ecryptfs_private_path(home, username, target, sizeof(target));
	if (!is_enc)
		strncpy(target, home, sizeof(target) - 1);

	/* Filesystem checks */
	if (!is_btrfs(target)) {
		bdfs_err("%s is not on BTRFS", target);
		return 1;
	}
	if (!is_btrfs_subvol(target)) {
		bdfs_err("%s is not a BTRFS subvolume — run 'bdfs home init' first",
			 target);
		return 1;
	}

	/* Build the snapshot directory path */
	char snap_dir[PATH_MAX];
	if (subdir[0])
		snprintf(snap_dir, sizeof(snap_dir), "%s/%s", snap_root, subdir);
	else
		strncpy(snap_dir, snap_root, sizeof(snap_dir) - 1);

	/* ── List ── */
	if (do_list) {
		DIR *d = opendir(snap_dir);
		if (!d) {
			if (errno == ENOENT) {
				if (cli->json_output)
					printf("{\"snapshots\":[]}\n");
				else
					printf("No snapshots found in %s\n", snap_dir);
				return 0;
			}
			bdfs_err("opendir %s: %s", snap_dir, strerror(errno));
			return 1;
		}
		if (cli->json_output)
			printf("{\"snapshots\":[");
		bool first = true;
		struct dirent *de;
		while ((de = readdir(d)) != NULL) {
			if (de->d_name[0] == '.') continue;
			char full[PATH_MAX];
			snprintf(full, sizeof(full), "%s/%s", snap_dir, de->d_name);
			if (!is_btrfs_subvol(full)) continue;
			if (cli->json_output)
				printf("%s\"%s\"", first ? "" : ",", de->d_name);
			else
				printf("%s\n", de->d_name);
			first = false;
		}
		closedir(d);
		if (cli->json_output)
			printf("]}\n");
		return 0;
	}

	/* ── Delete ── */
	if (delete_name[0]) {
		/* Validate: no path separators in name */
		if (strchr(delete_name, '/')) {
			bdfs_err("snapshot name must not contain '/'");
			return 1;
		}
		char snap_path[PATH_MAX];
		snprintf(snap_path, sizeof(snap_path), "%s/%s", snap_dir, delete_name);

		if (access(snap_path, F_OK) != 0) {
			bdfs_err("snapshot not found: %s", snap_path);
			return 1;
		}
		if (!is_btrfs_subvol(snap_path)) {
			bdfs_err("%s is not a BTRFS subvolume", snap_path);
			return 1;
		}

		/* btrfs subvolume delete requires root; use sudo if needed */
		const char *del_argv[8];
		int i = 0;
		if (geteuid() != 0)
			del_argv[i++] = "sudo";
		del_argv[i++] = "btrfs";
		del_argv[i++] = "subvolume";
		del_argv[i++] = "delete";
		del_argv[i++] = "-c";
		del_argv[i++] = snap_path;
		del_argv[i++] = NULL;

		if (run_cmd(del_argv) != 0) {
			bdfs_err("failed to delete snapshot %s", snap_path);
			return 1;
		}
		if (!cli->json_output)
			printf("Deleted snapshot %s\n", snap_path);
		else
			printf("{\"status\":0,\"deleted\":\"%s\"}\n", snap_path);
		return 0;
	}

	/* ── Create ── */
	if (mkdir(snap_root, 0700) < 0 && errno != EEXIST) {
		bdfs_err("mkdir %s: %s", snap_root, strerror(errno));
		return 1;
	}
	if (subdir[0] && (mkdir(snap_dir, 0700) < 0 && errno != EEXIST)) {
		bdfs_err("mkdir %s: %s", snap_dir, strerror(errno));
		return 1;
	}

	/* Build snapshot path */
	char snap_path[PATH_MAX];
	if (snap_name[0]) {
		if (strchr(snap_name, '/')) {
			bdfs_err("snapshot name must not contain '/'");
			return 1;
		}
		snprintf(snap_path, sizeof(snap_path), "%s/%s", snap_dir, snap_name);
	} else {
		/* Timestamp-based name */
		time_t now = time(NULL);
		struct tm *tm = localtime(&now);
		char ts[32];
		strftime(ts, sizeof(ts), "%Y-%m-%d_%H:%M:%S", tm);
		snprintf(snap_path, sizeof(snap_path), "%s/%s", snap_dir, ts);
	}

	if (access(snap_path, F_OK) == 0) {
		bdfs_err("snapshot already exists: %s", snap_path);
		return 1;
	}

	/*
	 * For ecryptfs homes the snapshot must be taken on the encrypted
	 * .Private path, not the decrypted mountpoint.
	 */
	const char *snap_src = is_enc ? target : home;

	const char *create[] = { "btrfs", "subvolume", "snapshot", "-r",
				 snap_src, snap_path, NULL };
	if (run_cmd(create) != 0) {
		bdfs_err("btrfs subvolume snapshot failed");
		return 1;
	}

	if (!cli->json_output)
		printf("Created snapshot %s\n", snap_path);
	else
		printf("{\"status\":0,\"snapshot\":\"%s\"}\n", snap_path);

	return 0;
}

/* ── bdfs home demote ────────────────────────────────────────────────────── */

/*
 * Compress a home snapshot subvolume into a DwarFS archive via the daemon.
 * The snapshot must be a read-only BTRFS subvolume (created by `bdfs home
 * snapshot`).  The resulting .dwarfs image is stored in
 * ~/.snapshots/archive/ by default.
 */
static int cmd_home_demote(struct bdfs_cli *cli, int argc, char *argv[])
{
	char user[256] = "";
	char archive_dir[PATH_MAX] = "";
	int opt;

	static const struct option opts[] = {
		{ "user",        required_argument, NULL, 'u' },
		{ "archive-dir", required_argument, NULL, 'a' },
		{ "help",        no_argument,       NULL, 'h' },
		{ NULL, 0, NULL, 0 }
	};

	while ((opt = getopt_long(argc, argv, "u:a:h", opts, NULL)) != -1) {
		switch (opt) {
		case 'u': strncpy(user,        optarg, sizeof(user) - 1);        break;
		case 'a': strncpy(archive_dir, optarg, sizeof(archive_dir) - 1); break;
		case 'h':
			printf("Usage: bdfs home demote [--user <name>] "
			       "[--archive-dir <path>] <snapshot-path>\n");
			return 0;
		default: return 1;
		}
	}

	if (optind >= argc) {
		bdfs_err("snapshot path required");
		return 1;
	}
	const char *snap_path = argv[optind];

	/* Validate the snapshot */
	if (!is_btrfs_subvol(snap_path)) {
		bdfs_err("%s is not a BTRFS subvolume", snap_path);
		return 1;
	}

	/* Determine archive directory */
	char home[PATH_MAX], username[256];
	if (resolve_home(user[0] ? user : NULL, home, sizeof(home),
			 username, sizeof(username)) < 0)
		return 1;

	if (!archive_dir[0]) {
		snprintf(archive_dir, sizeof(archive_dir),
			 "%s/.snapshots/archive", home);
	}
	if (mkdir(archive_dir, 0700) < 0 && errno != EEXIST) {
		bdfs_err("mkdir %s: %s", archive_dir, strerror(errno));
		return 1;
	}

	/* Derive image name from snapshot basename */
	const char *base = strrchr(snap_path, '/');
	base = base ? base + 1 : snap_path;
	char image_path[PATH_MAX];
	snprintf(image_path, sizeof(image_path), "%s/%s.dwarfs", archive_dir, base);

	if (!cli->json_output)
		printf("Demoting %s → %s\n", snap_path, image_path);

	/*
	 * Send BDFS_IOC_EXPORT_TO_DWARFS to the daemon.
	 * We use the snapshot path as both the btrfs_mount and the source;
	 * the daemon will create a temporary read-only snapshot of it.
	 */
	int ret = bdfs_cli_open_ctl(cli);
	if (ret) return 1;

	struct bdfs_ioctl_export_to_dwarfs arg;
	memset(&arg, 0, sizeof(arg));
	strncpy(arg.btrfs_mount, snap_path, sizeof(arg.btrfs_mount) - 1);
	strncpy(arg.image_name,  base,      sizeof(arg.image_name) - 1);
	arg.compression    = BDFS_COMPRESS_ZSTD;
	arg.block_size_bits = 22;
	arg.worker_threads  = 2;
	arg.flags           = BDFS_EXPORT_VERIFY;

	if (ioctl(cli->ctl_fd, BDFS_IOC_EXPORT_TO_DWARFS, &arg) < 0) {
		bdfs_err("BDFS_IOC_EXPORT_TO_DWARFS: %s", strerror(errno));
		return 1;
	}

	if (!cli->json_output)
		printf("Demote queued. Image will appear at %s\n", image_path);
	else
		printf("{\"status\":0,\"image\":\"%s\"}\n", image_path);

	return 0;
}

/* ── Dispatch ────────────────────────────────────────────────────────────── */

int cmd_home(struct bdfs_cli *cli, int argc, char *argv[])
{
	if (argc < 1) {
		fprintf(stderr,
			"Usage: bdfs home <subcommand> [options]\n"
			"\n"
			"Subcommands:\n"
			"  init      Convert a home directory to a BTRFS subvolume\n"
			"  snapshot  Create, delete, or list home directory snapshots\n"
			"  demote    Compress a home snapshot to a DwarFS archive\n"
			"\n"
			"Run 'bdfs home <subcommand> --help' for details.\n");
		return 1;
	}

	const char *sub = argv[0];
	int sub_argc = argc - 1;
	char **sub_argv = argv + 1;

	if (strcmp(sub, "init")     == 0) return cmd_home_init(cli, sub_argc, sub_argv);
	if (strcmp(sub, "snapshot") == 0) return cmd_home_snapshot(cli, sub_argc, sub_argv);
	if (strcmp(sub, "demote")   == 0) return cmd_home_demote(cli, sub_argc, sub_argv);

	bdfs_err("unknown home subcommand: %s", sub);
	return 1;
}
