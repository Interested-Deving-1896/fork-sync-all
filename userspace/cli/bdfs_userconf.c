// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * bdfs_userconf.c - User-level configuration (~/.config/bdfs/bdfs.conf)
 *
 * Parsed by CLI commands that operate on behalf of the current user (home
 * snapshots, per-user prune schedules).  The daemon's /etc/bdfs/bdfs.conf
 * is separate and parsed by the daemon itself.
 *
 * Format: INI-style, same as /etc/bdfs/bdfs.conf.
 *
 * [snapshots]
 * dir = ~/.snapshots          # default snapshot directory
 * keep = 10                   # default retention count
 *
 * [sources]
 * # Each entry is a path to snapshot automatically.
 * # Multiple entries allowed.
 * path = /home/alice
 * path = /home/alice/projects
 *
 * [demote]
 * archive_dir = ~/.snapshots/archive
 * compression = zstd
 * auto_demote_keep = 5        # keep N raw snapshots; demote the rest
 */
#define _GNU_SOURCE
#include <ctype.h>
#include <errno.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "bdfs_userconf.h"

/* ── Defaults ────────────────────────────────────────────────────────────── */

void bdfs_userconf_init(struct bdfs_userconf *cfg)
{
	memset(cfg, 0, sizeof(*cfg));
	cfg->keep            = 10;
	cfg->auto_demote_keep = 0;  /* disabled by default */
	cfg->compression     = BDFS_COMPRESS_ZSTD;

	/* Default snapshot dir: $HOME/.snapshots */
	const char *home = getenv("HOME");
	if (!home) {
		struct passwd *pw = getpwuid(getuid());
		home = pw ? pw->pw_dir : "/tmp";
	}
	snprintf(cfg->snapshot_dir, sizeof(cfg->snapshot_dir),
		 "%s/.snapshots", home);
	snprintf(cfg->archive_dir, sizeof(cfg->archive_dir),
		 "%s/.snapshots/archive", home);
}

/* ── Config file path ────────────────────────────────────────────────────── */

static void config_path(char *out, size_t sz)
{
	const char *xdg = getenv("XDG_CONFIG_HOME");
	if (xdg && xdg[0])
		snprintf(out, sz, "%s/bdfs/bdfs.conf", xdg);
	else {
		const char *home = getenv("HOME");
		if (!home) {
			struct passwd *pw = getpwuid(getuid());
			home = pw ? pw->pw_dir : "/tmp";
		}
		snprintf(out, sz, "%s/.config/bdfs/bdfs.conf", home);
	}
}

/* ── Parser ──────────────────────────────────────────────────────────────── */

static char *trim(char *s)
{
	while (isspace((unsigned char)*s)) s++;
	char *e = s + strlen(s);
	while (e > s && isspace((unsigned char)*(e - 1))) e--;
	*e = '\0';
	return s;
}

static uint32_t compression_from_name(const char *name)
{
	if (strcmp(name, "lzma")   == 0) return BDFS_COMPRESS_LZMA;
	if (strcmp(name, "lz4")    == 0) return BDFS_COMPRESS_LZ4;
	if (strcmp(name, "brotli") == 0) return BDFS_COMPRESS_BROTLI;
	if (strcmp(name, "none")   == 0) return BDFS_COMPRESS_NONE;
	return BDFS_COMPRESS_ZSTD; /* default */
}

int bdfs_userconf_load(struct bdfs_userconf *cfg)
{
	char path[512];
	config_path(path, sizeof(path));

	FILE *f = fopen(path, "r");
	if (!f) {
		if (errno == ENOENT)
			return 0; /* no user config — use defaults */
		return -errno;
	}

	char section[64] = "";
	char line[512];

	while (fgets(line, sizeof(line), f)) {
		char *s = trim(line);

		/* Skip comments and blank lines */
		if (!*s || *s == '#' || *s == ';')
			continue;

		/* Section header */
		if (*s == '[') {
			char *end = strchr(s, ']');
			if (end) {
				*end = '\0';
				strncpy(section, s + 1, sizeof(section) - 1);
			}
			continue;
		}

		/* key = value */
		char *eq = strchr(s, '=');
		if (!eq) continue;
		*eq = '\0';
		char *key = trim(s);
		char *val = trim(eq + 1);

		/* Strip inline comments */
		char *hash = strchr(val, '#');
		if (hash) { *hash = '\0'; val = trim(val); }

		if (strcmp(section, "snapshots") == 0) {
			if (strcmp(key, "dir") == 0)
				strncpy(cfg->snapshot_dir, val,
					sizeof(cfg->snapshot_dir) - 1);
			else if (strcmp(key, "keep") == 0)
				cfg->keep = (uint32_t)atoi(val);
		} else if (strcmp(section, "sources") == 0) {
			if (strcmp(key, "path") == 0 &&
			    cfg->source_count < BDFS_USERCONF_MAX_SOURCES) {
				strncpy(cfg->sources[cfg->source_count],
					val,
					sizeof(cfg->sources[0]) - 1);
				cfg->source_count++;
			}
		} else if (strcmp(section, "demote") == 0) {
			if (strcmp(key, "archive_dir") == 0)
				strncpy(cfg->archive_dir, val,
					sizeof(cfg->archive_dir) - 1);
			else if (strcmp(key, "compression") == 0)
				cfg->compression = compression_from_name(val);
			else if (strcmp(key, "auto_demote_keep") == 0)
				cfg->auto_demote_keep = (uint32_t)atoi(val);
		}
	}

	fclose(f);
	return 0;
}

/* ── Ensure config directory exists ─────────────────────────────────────── */

int bdfs_userconf_ensure_dir(void)
{
	char path[512];
	config_path(path, sizeof(path));

	/* Strip filename to get directory */
	char *slash = strrchr(path, '/');
	if (!slash) return 0;
	*slash = '\0';

	if (mkdir(path, 0700) < 0 && errno != EEXIST)
		return -errno;
	return 0;
}

/* ── Write default config ────────────────────────────────────────────────── */

int bdfs_userconf_write_default(void)
{
	char path[512];
	config_path(path, sizeof(path));

	if (bdfs_userconf_ensure_dir() < 0)
		return -errno;

	/* Don't overwrite existing config */
	if (access(path, F_OK) == 0)
		return 0;

	FILE *f = fopen(path, "w");
	if (!f) return -errno;

	fprintf(f,
"# ~/.config/bdfs/bdfs.conf - per-user bdfs configuration\n"
"\n"
"[snapshots]\n"
"# Directory where home snapshots are stored\n"
"#dir = ~/.snapshots\n"
"\n"
"# Number of snapshots to keep (oldest beyond this are pruned)\n"
"#keep = 10\n"
"\n"
"[sources]\n"
"# Home directories to snapshot automatically (one per line)\n"
"#path = %s\n"
"\n"
"[demote]\n"
"# Directory where DwarFS archives of old snapshots are stored\n"
"#archive_dir = ~/.snapshots/archive\n"
"\n"
"# Compression algorithm for DwarFS archives\n"
"# Options: zstd (default), lzma, lz4, brotli, none\n"
"#compression = zstd\n"
"\n"
"# Keep this many raw snapshots; demote older ones to DwarFS archives.\n"
"# 0 = disabled (never auto-demote)\n"
"#auto_demote_keep = 0\n",
		getenv("HOME") ? getenv("HOME") : "~");

	fclose(f);
	return 0;
}
