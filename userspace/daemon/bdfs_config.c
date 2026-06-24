// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * bdfs_config.c - Daemon configuration file parser
 *
 * Reads /etc/bdfs/bdfs.conf (or the path given by --config on the command
 * line) and populates struct bdfs_daemon_config.
 *
 * File format: INI-style, same as bdfs_userconf.c.
 *
 *   [daemon]
 *   ctl_device       = /dev/bdfs_ctl
 *   socket_path      = /run/bdfs/bdfs.sock
 *   state_dir        = /var/lib/bdfs
 *   worker_threads   = 4
 *   mkdwarfs_timeout = 2700
 *   shutdown_log     = /var/log/bdfs/workspace-shutdown.jsonl
 *   kubo_api         = http://127.0.0.1:5001
 *
 *   [tools]
 *   mkdwarfs      = mkdwarfs
 *   dwarfs        = dwarfs
 *   dwarfsextract = dwarfsextract
 *   dwarfsck      = dwarfsck
 *   pin_helper    = bdfs-pin-helper
 *
 * Unknown keys and sections are silently ignored so older config files
 * remain valid after upgrades.
 *
 * Call order:
 *   1. Zero-initialise struct bdfs_daemon_config.
 *   2. Call bdfs_config_load() to populate from file.
 *   3. Apply CLI flag overrides (they take precedence over the file).
 *   4. Call bdfs_daemon_init() which fills in compiled-in defaults for
 *      any fields still zero/empty.
 */

#define _GNU_SOURCE
#include <ctype.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>

#include "bdfs_daemon.h"
#include "bdfs_config.h"

#define BDFS_DEFAULT_CONFIG_PATH "/etc/bdfs/bdfs.conf"

/* ── Helpers ─────────────────────────────────────────────────────────────── */

/* Strip leading and trailing whitespace in-place. Returns pointer to start. */
static char *trim(char *s)
{
	while (isspace((unsigned char)*s))
		s++;
	char *end = s + strlen(s);
	while (end > s && isspace((unsigned char)*(end - 1)))
		*--end = '\0';
	return s;
}

/* Copy at most dstsz-1 bytes of src into dst, always NUL-terminating. */
static void set_str(char *dst, size_t dstsz, const char *src)
{
	strncpy(dst, src, dstsz - 1);
	dst[dstsz - 1] = '\0';
}

/* ── Parser ──────────────────────────────────────────────────────────────── */

/*
 * bdfs_config_load - parse a bdfs.conf file into *cfg.
 *
 * @path  path to the config file, or NULL to use the default
 *        (/etc/bdfs/bdfs.conf)
 * @cfg   destination; caller must have zero-initialised it
 *
 * Returns 0 on success, -ENOENT if the file does not exist (not an error —
 * the daemon runs fine with compiled-in defaults), or -errno on read error.
 */
int bdfs_config_load(const char *path, struct bdfs_daemon_config *cfg)
{
	if (!path || !path[0])
		path = BDFS_DEFAULT_CONFIG_PATH;

	FILE *f = fopen(path, "r");
	if (!f) {
		if (errno == ENOENT) {
			syslog(LOG_DEBUG,
			       "bdfs: config file %s not found, using defaults",
			       path);
			return -ENOENT;
		}
		syslog(LOG_WARNING, "bdfs: config open %s: %m", path);
		return -errno;
	}

	char line[512];
	char section[64] = "";
	int  lineno = 0;

	while (fgets(line, sizeof(line), f)) {
		lineno++;
		char *p = trim(line);

		/* Skip blank lines and comments */
		if (!*p || *p == '#' || *p == ';')
			continue;

		/* Section header */
		if (*p == '[') {
			char *end = strchr(p, ']');
			if (!end) {
				syslog(LOG_WARNING,
				       "bdfs: config %s:%d: malformed section",
				       path, lineno);
				continue;
			}
			*end = '\0';
			set_str(section, sizeof(section), p + 1);
			continue;
		}

		/* key = value */
		char *eq = strchr(p, '=');
		if (!eq) {
			syslog(LOG_WARNING,
			       "bdfs: config %s:%d: no '=' found, skipping",
			       path, lineno);
			continue;
		}
		*eq = '\0';
		char *key = trim(p);
		char *val = trim(eq + 1);

		/* Strip inline comments from value */
		char *comment = strchr(val, '#');
		if (comment) {
			*comment = '\0';
			val = trim(val);
		}

		/* ── [daemon] section ─────────────────────────────────── */
		if (strcmp(section, "daemon") == 0) {
			if (strcmp(key, "ctl_device") == 0)
				set_str(cfg->ctl_device,
					sizeof(cfg->ctl_device), val);
			else if (strcmp(key, "socket_path") == 0)
				set_str(cfg->socket_path,
					sizeof(cfg->socket_path), val);
			else if (strcmp(key, "state_dir") == 0)
				set_str(cfg->state_dir,
					sizeof(cfg->state_dir), val);
			else if (strcmp(key, "worker_threads") == 0)
				cfg->worker_threads = atoi(val);
			else if (strcmp(key, "mkdwarfs_timeout") == 0)
				cfg->mkdwarfs_timeout_s = atoi(val);
			else if (strcmp(key, "shutdown_log") == 0)
				set_str(cfg->shutdown_log_path,
					sizeof(cfg->shutdown_log_path), val);
			else if (strcmp(key, "kubo_api") == 0)
				set_str(cfg->kubo_api,
					sizeof(cfg->kubo_api), val);
			/* silently ignore unknown keys */

		/* ── [tools] section ──────────────────────────────────── */
		} else if (strcmp(section, "tools") == 0) {
			if (strcmp(key, "mkdwarfs") == 0)
				set_str(cfg->mkdwarfs_bin,
					sizeof(cfg->mkdwarfs_bin), val);
			else if (strcmp(key, "dwarfs") == 0)
				set_str(cfg->dwarfs_bin,
					sizeof(cfg->dwarfs_bin), val);
			else if (strcmp(key, "dwarfsextract") == 0)
				set_str(cfg->dwarfsextract_bin,
					sizeof(cfg->dwarfsextract_bin), val);
			else if (strcmp(key, "dwarfsck") == 0)
				set_str(cfg->dwarfsck_bin,
					sizeof(cfg->dwarfsck_bin), val);
			else if (strcmp(key, "pin_helper") == 0)
				set_str(cfg->pin_helper_bin,
					sizeof(cfg->pin_helper_bin), val);
		}
		/* silently ignore unknown sections */
	}

	fclose(f);
	syslog(LOG_INFO, "bdfs: loaded config from %s", path);
	return 0;
}
