// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * bdfs_fetch.c - Restore a workspace snapshot from an IPFS CID
 *
 * bdfs fetch --cid <CID> --dest <path>
 *            [--kubo-api <url>]
 *            [--keep-archive]
 *            [--compression zstd|lzma|lz4|brotli|none]
 *
 * Fetches a DwarFS archive pinned to IPFS by CID, extracts it into a new
 * BTRFS subvolume at <dest>, and optionally keeps the downloaded archive.
 *
 * This is the inverse of the workspace DELETE shutdown path:
 *
 *   DELETE:  workspace subvol → mkdwarfs → bdfs-pin-helper → IPFS CID
 *   FETCH:   IPFS CID → bdfs fetch → dwarfsextract → workspace subvol
 *
 * The Kubo HTTP API is used to retrieve the archive (GET /api/v0/cat?arg=<CID>).
 * The archive is streamed to a temporary file, then extracted with dwarfsextract.
 * If --dest is on a BTRFS filesystem, a read-write subvolume is created there;
 * otherwise a plain directory is used.
 *
 * Exit codes:
 *   0  success
 *   1  fetch or extract failed
 *   2  bad arguments
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include "bdfs.h"

/* Default Kubo HTTP API base URL */
#define BDFS_FETCH_DEFAULT_KUBO_API "http://127.0.0.1:5001"

/* Maximum CID length (CIDv1 base32 is ~59 chars; leave headroom) */
#define BDFS_CID_MAX 256

/* ── helpers ─────────────────────────────────────────────────────────────── */

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
	if (WIFEXITED(status)) return WEXITSTATUS(status);
	return -EIO;
}

/*
 * fetch_archive_via_curl - download CID from Kubo using curl.
 *
 * Kubo's /api/v0/cat endpoint streams the raw block data for a CID.
 * We use curl rather than implementing HTTP ourselves to avoid a libcurl
 * dependency in the C daemon — curl is universally available.
 */
static int fetch_archive_via_curl(const char *kubo_api, const char *cid,
				  const char *dest_path)
{
	char url[512];
	snprintf(url, sizeof(url), "%s/api/v0/cat?arg=%s", kubo_api, cid);

	const char *argv[] = {
		"curl", "-fsSL", "--output", dest_path,
		"--max-time", "1800",
		"-X", "POST",   /* Kubo API requires POST for /api/v0/cat */
		url,
		NULL
	};

	fprintf(stderr, "bdfs fetch: downloading ipfs://%s ...\n", cid);
	int ret = run_cmd(argv);
	if (ret != 0) {
		bdfs_err("curl failed (exit %d) fetching CID %s from %s",
			 ret, cid, kubo_api);
		return -EIO;
	}

	/* Verify the file is non-empty */
	struct stat st;
	if (stat(dest_path, &st) < 0 || st.st_size == 0) {
		bdfs_err("downloaded archive is empty for CID %s", cid);
		return -EIO;
	}

	fprintf(stderr, "bdfs fetch: downloaded %lld bytes\n",
		(long long)st.st_size);
	return 0;
}

/*
 * extract_dwarfs_archive - run dwarfsextract to restore archive to dest_dir.
 *
 * If dest_dir is on a BTRFS filesystem, create it as a subvolume first.
 * Falls back to mkdir if btrfs-subvolume-create fails (non-BTRFS dest).
 */
static int extract_dwarfs_archive(const char *archive_path,
				  const char *dest_dir,
				  const char *dwarfsextract_bin)
{
	/* Try to create a BTRFS subvolume; fall back to plain mkdir */
	const char *btrfs_argv[] = {
		"btrfs", "subvolume", "create", dest_dir, NULL
	};
	if (run_cmd(btrfs_argv) != 0) {
		if (mkdir(dest_dir, 0755) < 0 && errno != EEXIST) {
			bdfs_err("mkdir %s: %s", dest_dir, strerror(errno));
			return -errno;
		}
	}

	const char *bin = dwarfsextract_bin && dwarfsextract_bin[0]
			  ? dwarfsextract_bin : "dwarfsextract";

	const char *argv[] = {
		bin, "-i", archive_path, "-o", dest_dir, NULL
	};

	fprintf(stderr, "bdfs fetch: extracting archive to %s ...\n", dest_dir);
	int ret = run_cmd(argv);
	if (ret != 0) {
		bdfs_err("dwarfsextract failed (exit %d)", ret);
		return -EIO;
	}

	fprintf(stderr, "bdfs fetch: extraction complete\n");
	return 0;
}

/* ── cmd_fetch ───────────────────────────────────────────────────────────── */

int cmd_fetch(struct bdfs_cli *cli, int argc, char *argv[])
{
	char cid[BDFS_CID_MAX]     = {0};
	char dest[PATH_MAX]        = {0};
	char kubo_api[512]         = BDFS_FETCH_DEFAULT_KUBO_API;
	int  keep_archive          = 0;
	int  opt;

	static const struct option opts[] = {
		{ "cid",          required_argument, NULL, 'c' },
		{ "dest",         required_argument, NULL, 'd' },
		{ "kubo-api",     required_argument, NULL, 'k' },
		{ "keep-archive", no_argument,       NULL, 'K' },
		{ "help",         no_argument,       NULL, 'h' },
		{ NULL, 0, NULL, 0 }
	};

	while ((opt = getopt_long(argc, argv, "c:d:k:Kh", opts, NULL)) != -1) {
		switch (opt) {
		case 'c':
			strncpy(cid, optarg, sizeof(cid) - 1);
			break;
		case 'd':
			strncpy(dest, optarg, sizeof(dest) - 1);
			break;
		case 'k':
			strncpy(kubo_api, optarg, sizeof(kubo_api) - 1);
			break;
		case 'K':
			keep_archive = 1;
			break;
		case 'h':
			printf(
"Usage: bdfs fetch --cid <CID> --dest <path>\n"
"                  [--kubo-api <url>] [--keep-archive]\n"
"\n"
"Restore a workspace snapshot from an IPFS CID.\n"
"\n"
"  --cid <CID>          IPFS CID of the DwarFS archive to fetch\n"
"  --dest <path>        Destination directory (created as BTRFS subvol if possible)\n"
"  --kubo-api <url>     Kubo HTTP API base URL (default: %s)\n"
"  --keep-archive       Keep the downloaded .dwarfs archive after extraction\n"
"\n"
"The CID is recorded in the workspace shutdown log (bdfs shutdown-log show).\n"
"This command is the inverse of the workspace DELETE shutdown path.\n",
			BDFS_FETCH_DEFAULT_KUBO_API);
			return 0;
		default:
			return 2;
		}
	}

	if (!cid[0]) {
		bdfs_err("--cid is required");
		return 2;
	}
	if (!dest[0]) {
		bdfs_err("--dest is required");
		return 2;
	}

	/* Build a temp path for the downloaded archive */
	char archive_tmp[PATH_MAX];
	snprintf(archive_tmp, sizeof(archive_tmp),
		 "/tmp/bdfs-fetch-%s.dwarfs", cid);

	/* Step 1: fetch from IPFS */
	int ret = fetch_archive_via_curl(kubo_api, cid, archive_tmp);
	if (ret) return 1;

	/* Step 2: extract to dest */
	ret = extract_dwarfs_archive(archive_tmp, dest,
				     cli->cfg.dwarfsextract_bin);
	if (ret) {
		unlink(archive_tmp);
		return 1;
	}

	/* Step 3: clean up archive unless --keep-archive */
	if (!keep_archive)
		unlink(archive_tmp);

	if (!cli->json_output) {
		printf("Fetched ipfs://%s → %s\n", cid, dest);
	} else {
		printf("{\"status\":0,\"cid\":\"%s\",\"dest\":\"%s\"}\n",
		       cid, dest);
	}
	return 0;
}
