// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * bdfs_verify.c - verify subcommand
 *
 *   bdfs verify --partition <uuid>  [--image-id <id>]  [--checksum sha512]
 *               [--fix]  [--quiet]
 *
 * Runs dwarfsck against every DwarFS image on a partition (or a single
 * image when --image-id is given).  Reports per-image pass/fail and an
 * overall exit code of 0 (all pass) or 1 (any fail).
 *
 * With --checksum the tool also verifies per-file checksums inside each
 * image, not just the image-level block checksums.
 *
 * With --fix (future: not yet supported by dwarfsck) a repair attempt
 * would be made; currently this flag is accepted but emits a warning.
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <getopt.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <time.h>

#include "bdfs.h"

/* Locate dwarfsck on PATH */
static const char *find_dwarfsck(void)
{
	static const char *candidates[] = {
		"dwarfsck",
		"/usr/bin/dwarfsck",
		"/usr/local/bin/dwarfsck",
		NULL
	};
	int i;
	for (i = 0; candidates[i]; i++) {
		if (access(candidates[i], X_OK) == 0)
			return candidates[i];
	}
	return "dwarfsck"; /* fall back; let execvp report the error */
}

/*
 * run_dwarfsck - Run dwarfsck on a single image path.
 *
 * Returns 0 on pass, non-zero on failure.
 * Output is captured and printed only on failure (or always if verbose).
 */
static int run_dwarfsck(const char *image_path,
			const char *checksum_algo,
			bool verbose,
			bool quiet)
{
	const char *dwarfsck = find_dwarfsck();
	const char *argv[16];
	int i = 0;
	int pipefd[2];
	pid_t pid;
	int status;
	char buf[4096];
	ssize_t n;
	char output[65536] = {0};
	size_t out_len = 0;

	argv[i++] = dwarfsck;
	argv[i++] = image_path;
	if (checksum_algo && checksum_algo[0]) {
		argv[i++] = "--checksum";
		argv[i++] = checksum_algo;
	}
	if (!verbose)
		argv[i++] = "-q";
	argv[i++] = NULL;

	if (pipe(pipefd) < 0)
		return -errno;

	pid = fork();
	if (pid < 0) {
		close(pipefd[0]);
		close(pipefd[1]);
		return -errno;
	}

	if (pid == 0) {
		close(pipefd[0]);
		dup2(pipefd[1], STDOUT_FILENO);
		dup2(pipefd[1], STDERR_FILENO);
		close(pipefd[1]);
		execvp(dwarfsck, (char *const *)argv);
		_exit(127);
	}

	close(pipefd[1]);

	/* Capture output */
	while ((n = read(pipefd[0], buf, sizeof(buf))) > 0) {
		if (out_len + (size_t)n < sizeof(output) - 1) {
			memcpy(output + out_len, buf, n);
			out_len += n;
		}
	}
	close(pipefd[0]);

	waitpid(pid, &status, 0);

	int rc = (WIFEXITED(status) && WEXITSTATUS(status) == 0) ? 0 : 1;

	if (rc != 0 && !quiet) {
		fprintf(stderr, "  dwarfsck output:\n");
		fputs(output, stderr);
	} else if (verbose && out_len > 0) {
		fputs(output, stdout);
	}

	return rc;
}

/* ── verify ─────────────────────────────────────────────────────────────── */

int cmd_verify(struct bdfs_cli *cli, int argc, char *argv[])
{
	struct bdfs_ioctl_list_dwarfs_images list_arg;
	struct bdfs_dwarfs_image *images = NULL;
	uint8_t partition_uuid[16];
	uint64_t filter_image_id = 0;
	bool has_image_filter = false;
	bool quiet = false;
	bool fix = false;
	const char *checksum_algo = NULL;
	uint32_t i, cap = 64;
	int pass = 0, fail = 0, skip = 0;
	int opt, ret;
	struct timespec t_start, t_end;

	static const struct option opts[] = {
		{ "partition", required_argument, NULL, 'p' },
		{ "image-id",  required_argument, NULL, 'I' },
		{ "checksum",  required_argument, NULL, 'c' },
		{ "fix",       no_argument,       NULL, 'f' },
		{ "quiet",     no_argument,       NULL, 'q' },
		{ "help",      no_argument,       NULL, 'h' },
		{ NULL, 0, NULL, 0 }
	};

	memset(partition_uuid, 0, sizeof(partition_uuid));

	while ((opt = getopt_long(argc, argv, "p:I:c:fqh", opts, NULL)) != -1) {
		switch (opt) {
		case 'p':
			if (bdfs_str_to_uuid(optarg, partition_uuid) < 0) {
				bdfs_err("invalid partition UUID: %s", optarg);
				return 1;
			}
			break;
		case 'I':
			filter_image_id = (uint64_t)strtoull(optarg, NULL, 0);
			has_image_filter = true;
			break;
		case 'c':
			checksum_algo = optarg;
			break;
		case 'f':
			fix = true;
			break;
		case 'q':
			quiet = true;
			break;
		case 'h':
			printf(
"Usage: bdfs verify --partition <uuid> [OPTIONS]\n"
"\n"
"Options:\n"
"  --image-id <id>      Verify a single image (default: all images)\n"
"  --checksum <algo>    Also verify per-file checksums (sha512, sha256, md5)\n"
"  --fix                Attempt repair (not yet supported by dwarfsck)\n"
"  --quiet              Suppress per-image output on success\n"
"\n"
"Exit code: 0 if all images pass, 1 if any fail.\n"
			);
			return 0;
		default:
			return 1;
		}
	}

	if (fix) {
		fprintf(stderr,
			"warning: --fix is not yet supported by dwarfsck; "
			"proceeding with verification only\n");
	}

	ret = bdfs_cli_open_ctl(cli);
	if (ret) return 1;

	/* Fetch image list */
	images = calloc(cap, sizeof(*images));
	if (!images) { bdfs_err("out of memory"); return 1; }

	memset(&list_arg, 0, sizeof(list_arg));
	memcpy(list_arg.partition_uuid, partition_uuid, 16);
	list_arg.count  = cap;
	list_arg.images = images;

	if (ioctl(cli->ctl_fd, BDFS_IOC_LIST_DWARFS_IMAGES, &list_arg) < 0) {
		bdfs_err("BDFS_IOC_LIST_DWARFS_IMAGES: %s", strerror(errno));
		free(images);
		return 1;
	}

	if (list_arg.total > cap) {
		free(images);
		cap = list_arg.total;
		images = calloc(cap, sizeof(*images));
		if (!images) { bdfs_err("out of memory"); return 1; }
		list_arg.count  = cap;
		list_arg.images = images;
		ioctl(cli->ctl_fd, BDFS_IOC_LIST_DWARFS_IMAGES, &list_arg);
	}

	if (list_arg.count == 0) {
		if (!quiet)
			printf("No DwarFS images found on partition.\n");
		free(images);
		return 0;
	}

	if (!quiet && !cli->json_output) {
		char uuid_str[37];
		bdfs_uuid_to_str(partition_uuid, uuid_str);
		printf("Verifying %u image(s) on partition %s\n\n",
		       has_image_filter ? 1 : list_arg.count, uuid_str);
	}

	if (cli->json_output)
		printf("[");

	clock_gettime(CLOCK_MONOTONIC, &t_start);

	for (i = 0; i < list_arg.count; i++) {
		struct bdfs_dwarfs_image *img = &images[i];
		int img_ret;

		if (has_image_filter && img->image_id != filter_image_id) {
			skip++;
			continue;
		}

		if (!img->backing_path[0]) {
			if (!quiet)
				printf("  [%llu] %-40s  SKIP (no backing path)\n",
				       (unsigned long long)img->image_id,
				       img->name);
			skip++;
			continue;
		}

		if (!quiet && !cli->json_output)
			printf("  [%llu] %-40s  ",
			       (unsigned long long)img->image_id, img->name);

		img_ret = run_dwarfsck(img->backing_path, checksum_algo,
				       cli->verbose, quiet);

		if (cli->json_output) {
			char uuid_str[37];
			bdfs_uuid_to_str(img->uuid, uuid_str);
			if (i > 0 && (pass + fail) > 0) printf(",");
			printf("{\"id\":%llu,\"name\":\"%s\","
			       "\"path\":\"%s\",\"result\":\"%s\"}",
			       (unsigned long long)img->image_id,
			       img->name, img->backing_path,
			       img_ret == 0 ? "pass" : "fail");
		} else if (!quiet) {
			printf("%s\n", img_ret == 0 ? "PASS" : "FAIL");
		}

		if (img_ret == 0)
			pass++;
		else
			fail++;
	}

	clock_gettime(CLOCK_MONOTONIC, &t_end);
	double elapsed = (t_end.tv_sec - t_start.tv_sec) +
			 (t_end.tv_nsec - t_start.tv_nsec) / 1e9;

	if (cli->json_output) {
		printf("]\n");
		printf("{\"pass\":%d,\"fail\":%d,\"skip\":%d,"
		       "\"elapsed_s\":%.2f}\n",
		       pass, fail, skip, elapsed);
	} else if (!quiet) {
		printf("\nResults: %d passed, %d failed, %d skipped"
		       "  (%.2fs)\n",
		       pass, fail, skip, elapsed);
	}

	free(images);
	return fail > 0 ? 1 : 0;
}
