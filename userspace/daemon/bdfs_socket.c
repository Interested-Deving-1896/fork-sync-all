// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * bdfs_socket.c - Unix domain socket server for the bdfs CLI
 *
 * The daemon exposes a simple request/response protocol over a Unix socket.
 * The bdfs CLI tool connects, sends a JSON-encoded command, and receives a
 * JSON-encoded response.  This avoids requiring the CLI to open /dev/bdfs_ctl
 * directly (which requires root) while still allowing privileged operations
 * to be delegated through the daemon.
 *
 * Protocol:
 *   Request:  { "cmd": "<command>", "args": { ... } }\n
 *   Response: { "status": 0, "data": { ... } }\n
 *             { "status": -<errno>, "error": "<message>" }\n
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <inttypes.h>
#include <syslog.h>
#include <dirent.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>

#include "bdfs_daemon.h"
#include "bdfs_policy.h"

#define BDFS_SOCK_BACKLOG   8
#define BDFS_SOCK_BUFSIZE   65536

int bdfs_socket_init(struct bdfs_daemon *d)
{
	struct sockaddr_un addr;
	int fd;
	char *dir_end;
	char dir[256];

	/* Ensure the socket directory exists */
	strncpy(dir, d->cfg.socket_path, sizeof(dir) - 1);
	dir_end = strrchr(dir, '/');
	if (dir_end) {
		*dir_end = '\0';
		if (mkdir(dir, 0755) < 0 && errno != EEXIST) {
			syslog(LOG_ERR, "bdfs: socket dir %s: %m", dir);
			return -errno;
		}
	}

	fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
	if (fd < 0) {
		syslog(LOG_ERR, "bdfs: unix socket: %m");
		return -errno;
	}

	unlink(d->cfg.socket_path);

	memset(&addr, 0, sizeof(addr));
	addr.sun_family = AF_UNIX;
	strncpy(addr.sun_path, d->cfg.socket_path, sizeof(addr.sun_path) - 1);

	if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		syslog(LOG_ERR, "bdfs: socket bind %s: %m", d->cfg.socket_path);
		close(fd);
		return -errno;
	}

	chmod(d->cfg.socket_path, 0660);

	if (listen(fd, BDFS_SOCK_BACKLOG) < 0) {
		syslog(LOG_ERR, "bdfs: socket listen: %m");
		close(fd);
		return -errno;
	}

	d->sock_fd = fd;
	syslog(LOG_INFO, "bdfs: CLI socket at %s", d->cfg.socket_path);
	return 0;
}

/*
 * Handle a single CLI connection.  Reads one newline-terminated JSON request,
 * dispatches it, and writes a JSON response.
 */
static void bdfs_handle_client(struct bdfs_daemon *d, int client_fd)
{
	char req[BDFS_SOCK_BUFSIZE];
	char resp[BDFS_SOCK_BUFSIZE];
	ssize_t n;
	int status = 0;

	n = recv(client_fd, req, sizeof(req) - 1, 0);
	if (n <= 0)
		goto out;
	req[n] = '\0';

	/*
	 * Command dispatch.  Uses simple string matching on the JSON "cmd"
	 * field — sufficient given the fixed protocol schema.  A real JSON
	 * parser (cJSON/jsmn) should replace this if the protocol grows.
	 *
	 * Field extraction helpers:
	 *   str_field(req, key, buf, bufsz)  — extract a quoted string value
	 *   int_field(req, key)              — extract an integer value
	 *   bool_field(req, key)             — extract a boolean value
	 */
#define str_field(req, key, buf, bufsz) do { \
	char *_p = strstr((req), "\"" key "\":\""); \
	if (_p) { \
		_p += strlen("\"" key "\":\""); \
		char *_e = strchr(_p, '"'); \
		if (_e) { \
			size_t _l = (size_t)(_e - _p); \
			if (_l >= (bufsz)) _l = (bufsz) - 1; \
			strncpy((buf), _p, _l); \
			(buf)[_l] = '\0'; \
		} \
	} \
} while (0)

#define int_field(req, key) ({ \
	int _v = 0; \
	char *_p = strstr((req), "\"" key "\":"); \
	if (_p) _v = atoi(_p + strlen("\"" key "\":")); \
	_v; \
})

#define bool_field(req, key) (!!strstr((req), "\"" key "\":true"))

	if (strstr(req, "\"cmd\":\"list_partitions\"") ||
	    strstr(req, "\"list-partitions\"")) {
		/*
		 * Walk /proc/mounts for btrfs entries and return their
		 * device paths.  Falls back to an empty list on error.
		 */
		FILE *mf = fopen("/proc/mounts", "r");
		char *pos = resp;
		size_t rem = sizeof(resp);
		int written = snprintf(pos, rem,
				       "{\"status\":0,\"data\":{\"partitions\":[");
		pos += written; rem -= written;
		int first = 1;
		if (mf) {
			char line[512];
			while (fgets(line, sizeof(line), mf) && rem > 4) {
				char dev[256] = {0}, mnt[256] = {0}, fs[32] = {0};
				if (sscanf(line, "%255s %255s %31s", dev, mnt, fs) == 3
				    && strcmp(fs, "btrfs") == 0) {
					written = snprintf(pos, rem, "%s\"%s\"",
							   first ? "" : ",", dev);
					pos += written; rem -= written;
					first = 0;
				}
			}
			fclose(mf);
		}
		snprintf(pos, rem, "]}}\n");

	} else if (strstr(req, "\"cmd\":\"list_images\"")) {
		/*
		 * Return .dwarfs files found under the configured archive
		 * directory (cfg.archive_dir, default /var/lib/bdfs/archives).
		 */
		const char *archive_dir = d->cfg.archive_dir[0]
					  ? d->cfg.archive_dir
					  : "/var/lib/bdfs/archives";
		char *pos = resp;
		size_t rem = sizeof(resp);
		int written = snprintf(pos, rem,
				       "{\"status\":0,\"data\":{\"images\":[");
		pos += written; rem -= written;

		DIR *dir = opendir(archive_dir);
		int first = 1;
		if (dir) {
			struct dirent *de;
			while ((de = readdir(dir)) != NULL && rem > 4) {
				size_t nlen = strlen(de->d_name);
				if (nlen > 7 &&
				    strcmp(de->d_name + nlen - 7, ".dwarfs") == 0) {
					written = snprintf(pos, rem, "%s\"%s/%s\"",
							   first ? "" : ",",
							   archive_dir, de->d_name);
					pos += written; rem -= written;
					first = 0;
				}
			}
			closedir(dir);
		}
		snprintf(pos, rem, "]}}\n");

	} else if (strstr(req, "\"cmd\":\"list_mounts\"")) {
		/* Return all currently tracked blend mount points. */
		char *pos = resp;
		size_t rem = sizeof(resp);
		int written = snprintf(pos, rem,
				       "{\"status\":0,\"data\":{\"mounts\":[");
		pos += written; rem -= written;

		pthread_mutex_lock(&d->mounts_lock);
		struct bdfs_mount_entry *e;
		int first = 1;
		TAILQ_FOREACH(e, &d->mounts, entry) {
			if (rem <= 4) break;
			written = snprintf(pos, rem, "%s\"%s\"",
					   first ? "" : ",", e->mount_point);
			pos += written; rem -= written;
			first = 0;
		}
		pthread_mutex_unlock(&d->mounts_lock);
		snprintf(pos, rem, "]}}\n");

	} else if (strstr(req, "\"cmd\":\"blend_mount\"")) {
		char image[BDFS_PATH_MAX]   = {0};
		char subvol[BDFS_PATH_MAX]  = {0};
		char mp[BDFS_PATH_MAX]      = {0};
		bool userspace = bool_field(req, "userspace");

		str_field(req, "image",      image,  sizeof(image));
		str_field(req, "subvol",     subvol, sizeof(subvol));
		str_field(req, "mountpoint", mp,     sizeof(mp));

		if (!image[0] || !subvol[0] || !mp[0]) {
			snprintf(resp, sizeof(resp),
				 "{\"status\":-22,\"error\":\"image, subvol and mountpoint required\"}\n");
			goto send;
		}

		struct bdfs_job *job = bdfs_job_alloc(
			userspace ? BDFS_JOB_MOUNT_BLEND_USERSPACE
				  : BDFS_JOB_MOUNT_BLEND);
		if (!job) {
			snprintf(resp, sizeof(resp),
				 "{\"status\":-12,\"error\":\"out of memory\"}\n");
			goto send;
		}

		if (userspace) {
			strncpy(job->mount_blend_userspace.dwarfs_image, image,
				BDFS_PATH_MAX - 1);
			strncpy(job->mount_blend_userspace.btrfs_upper, subvol,
				BDFS_PATH_MAX - 1);
			strncpy(job->mount_blend_userspace.blend_mount, mp,
				BDFS_PATH_MAX - 1);
		} else {
			strncpy(job->mount_blend.dwarfs_mount, image,
				BDFS_PATH_MAX - 1);
			strncpy(job->mount_blend.btrfs_mount, subvol,
				BDFS_PATH_MAX - 1);
			strncpy(job->mount_blend.blend_mount, mp,
				BDFS_PATH_MAX - 1);
		}

		int r = bdfs_daemon_enqueue(d, job);
		if (r == 0)
			snprintf(resp, sizeof(resp),
				 "{\"status\":\"ok\",\"data\":{\"mountpoint\":\"%s\"}}\n", mp);
		else
			snprintf(resp, sizeof(resp),
				 "{\"status\":%d,\"error\":\"enqueue failed\"}\n", r);

	} else if (strstr(req, "\"cmd\":\"umount\"")) {
		char mp[BDFS_PATH_MAX] = {0};
		str_field(req, "mountpoint", mp, sizeof(mp));

		if (!mp[0]) {
			snprintf(resp, sizeof(resp),
				 "{\"status\":-22,\"error\":\"mountpoint required\"}\n");
			goto send;
		}

		struct bdfs_job *job = bdfs_job_alloc(BDFS_JOB_UMOUNT_BLEND);
		if (!job) {
			snprintf(resp, sizeof(resp),
				 "{\"status\":-12,\"error\":\"out of memory\"}\n");
			goto send;
		}
		strncpy(job->umount_dwarfs.mount_point, mp, BDFS_PATH_MAX - 1);

		int r = bdfs_daemon_enqueue(d, job);
		if (r == 0)
			snprintf(resp, sizeof(resp), "{\"status\":\"ok\"}\n");
		else
			snprintf(resp, sizeof(resp),
				 "{\"status\":%d,\"error\":\"enqueue failed\"}\n", r);

	} else if (strstr(req, "\"cmd\":\"mount\"")) {
		/* Mount a bare DwarFS image (no blend). */
		char image[BDFS_PATH_MAX] = {0};
		char mp[BDFS_PATH_MAX]    = {0};
		int  cache_mb = int_field(req, "cache_size_mb");

		str_field(req, "image",      image, sizeof(image));
		str_field(req, "mountpoint", mp,    sizeof(mp));

		if (!image[0] || !mp[0]) {
			snprintf(resp, sizeof(resp),
				 "{\"status\":-22,\"error\":\"image and mountpoint required\"}\n");
			goto send;
		}

		struct bdfs_job *job = bdfs_job_alloc(BDFS_JOB_MOUNT_DWARFS);
		if (!job) {
			snprintf(resp, sizeof(resp),
				 "{\"status\":-12,\"error\":\"out of memory\"}\n");
			goto send;
		}
		strncpy(job->mount_dwarfs.image_path,  image, BDFS_PATH_MAX - 1);
		strncpy(job->mount_dwarfs.mount_point, mp,    BDFS_PATH_MAX - 1);
		job->mount_dwarfs.cache_size_mb = cache_mb > 0 ? (uint32_t)cache_mb : 256;

		int r = bdfs_daemon_enqueue(d, job);
		if (r == 0)
			snprintf(resp, sizeof(resp),
				 "{\"status\":\"ok\",\"data\":{\"mountpoint\":\"%s\"}}\n", mp);
		else
			snprintf(resp, sizeof(resp),
				 "{\"status\":%d,\"error\":\"enqueue failed\"}\n", r);

	} else if (strstr(req, "\"cmd\":\"import\"")) {
		char image[BDFS_PATH_MAX]  = {0};
		char target[BDFS_PATH_MAX] = {0};
		char btrfs[BDFS_PATH_MAX]  = {0};

		str_field(req, "image",  image,  sizeof(image));
		str_field(req, "target", target, sizeof(target));
		str_field(req, "btrfs",  btrfs,  sizeof(btrfs));

		if (!image[0] || !target[0]) {
			snprintf(resp, sizeof(resp),
				 "{\"status\":-22,\"error\":\"image and target required\"}\n");
			goto send;
		}

		struct bdfs_job *job = bdfs_job_alloc(BDFS_JOB_IMPORT_FROM_DWARFS);
		if (!job) {
			snprintf(resp, sizeof(resp),
				 "{\"status\":-12,\"error\":\"out of memory\"}\n");
			goto send;
		}
		strncpy(job->import_from_dwarfs.image_path,  image,  BDFS_PATH_MAX - 1);
		strncpy(job->import_from_dwarfs.subvol_name, target, BDFS_NAME_MAX);
		if (btrfs[0])
			strncpy(job->import_from_dwarfs.btrfs_mount, btrfs,
				BDFS_PATH_MAX - 1);

		int r = bdfs_daemon_enqueue(d, job);
		if (r == 0)
			snprintf(resp, sizeof(resp),
				 "{\"status\":\"ok\",\"data\":{\"target\":\"%s\"}}\n", target);
		else
			snprintf(resp, sizeof(resp),
				 "{\"status\":%d,\"error\":\"enqueue failed\"}\n", r);

	} else if (strstr(req, "\"cmd\":\"demote\"")) {
		char subvol[BDFS_PATH_MAX] = {0};
		char output[BDFS_PATH_MAX] = {0};
		char btrfs[BDFS_PATH_MAX]  = {0};

		str_field(req, "subvol", subvol, sizeof(subvol));
		str_field(req, "output", output, sizeof(output));
		str_field(req, "btrfs",  btrfs,  sizeof(btrfs));

		if (!subvol[0] || !output[0]) {
			snprintf(resp, sizeof(resp),
				 "{\"status\":-22,\"error\":\"subvol and output required\"}\n");
			goto send;
		}

		struct bdfs_job *job = bdfs_job_alloc(BDFS_JOB_EXPORT_TO_DWARFS);
		if (!job) {
			snprintf(resp, sizeof(resp),
				 "{\"status\":-12,\"error\":\"out of memory\"}\n");
			goto send;
		}
		if (btrfs[0])
			strncpy(job->export_to_dwarfs.btrfs_mount, btrfs,
				BDFS_PATH_MAX - 1);
		strncpy(job->export_to_dwarfs.image_path, output, BDFS_PATH_MAX - 1);
		/* subvol_id 0 means the job handler resolves by path */
		job->export_to_dwarfs.subvol_id = 0;
		/* Store subvol path in image_name as a hint for the handler */
		strncpy(job->export_to_dwarfs.image_name, subvol, BDFS_NAME_MAX);

		int r = bdfs_daemon_enqueue(d, job);
		if (r == 0)
			snprintf(resp, sizeof(resp),
				 "{\"status\":\"ok\",\"data\":{\"output\":\"%s\"}}\n", output);
		else
			snprintf(resp, sizeof(resp),
				 "{\"status\":%d,\"error\":\"enqueue failed\"}\n", r);

	} else if (strstr(req, "\"cmd\":\"prune\"")) {
		char subvol[BDFS_PATH_MAX]   = {0};
		char pattern[256]            = {0};
		int  keep        = int_field(req, "keep");
		bool demote_first = bool_field(req, "demote_first");
		bool dry_run      = bool_field(req, "dry_run");

		str_field(req, "subvol",  subvol,  sizeof(subvol));
		str_field(req, "pattern", pattern, sizeof(pattern));

		if (!subvol[0] || keep <= 0) {
			snprintf(resp, sizeof(resp),
				 "{\"status\":-22,\"error\":\"subvol and keep > 0 required\"}\n");
			goto send;
		}

		struct bdfs_job *job = bdfs_job_alloc(BDFS_JOB_PRUNE);
		if (!job) {
			snprintf(resp, sizeof(resp),
				 "{\"status\":-12,\"error\":\"out of memory\"}\n");
			goto send;
		}
		strncpy(job->prune.btrfs_mount,   subvol,  BDFS_PATH_MAX - 1);
		strncpy(job->prune.name_pattern,  pattern, sizeof(job->prune.name_pattern) - 1);
		job->prune.keep_count = (uint32_t)keep;
		if (demote_first) job->prune.flags |= BDFS_PRUNE_DEMOTE_FIRST;
		if (dry_run)      job->prune.flags |= BDFS_PRUNE_DRY_RUN;

		int r = bdfs_daemon_enqueue(d, job);
		if (r == 0)
			snprintf(resp, sizeof(resp), "{\"status\":\"ok\"}\n");
		else
			snprintf(resp, sizeof(resp),
				 "{\"status\":%d,\"error\":\"enqueue failed\"}\n", r);

	} else if (strstr(req, "\"cmd\":\"autosnap_rollback\"")) {
		char btrfs_mount[BDFS_PATH_MAX] = {0};
		char snapshot_name[BDFS_NAME_MAX + 1] = {0};

		str_field(req, "btrfs_mount",   btrfs_mount,    sizeof(btrfs_mount));
		str_field(req, "snapshot_name", snapshot_name,  sizeof(snapshot_name));

		if (!btrfs_mount[0] || !snapshot_name[0]) {
			snprintf(resp, sizeof(resp),
				 "{\"status\":-22,\"error\":"
				 "\"btrfs_mount and snapshot_name required\"}\n");
			goto send;
		}

		if (strncmp(snapshot_name, "autosnap-", 9) != 0) {
			snprintf(resp, sizeof(resp),
				 "{\"status\":-22,\"error\":"
				 "\"snapshot_name must start with autosnap-\"}\n");
			goto send;
		}

		struct bdfs_job *job = bdfs_job_alloc(BDFS_JOB_AUTOSNAP_ROLLBACK);
		if (!job) {
			snprintf(resp, sizeof(resp),
				 "{\"status\":-12,\"error\":\"out of memory\"}\n");
			goto send;
		}

		strncpy(job->autosnap_rollback.btrfs_mount,
			btrfs_mount, BDFS_PATH_MAX - 1);
		strncpy(job->autosnap_rollback.snapshot_name,
			snapshot_name, BDFS_NAME_MAX);

		int r = bdfs_daemon_enqueue(d, job);
		if (r == 0)
			snprintf(resp, sizeof(resp),
				 "{\"status\":\"ok\","
				 "\"message\":\"rollback to '%s' queued; "
				 "reboot to activate\"}\n",
				 snapshot_name);
		else
			snprintf(resp, sizeof(resp),
				 "{\"status\":%d,\"error\":\"enqueue failed\"}\n",
				 r);

	} else if (strstr(req, "\"cmd\":\"status\"") ||
		   strstr(req, "\"status\"")) {
		/* Count queued jobs */
		int queue_depth = 0;
		pthread_mutex_lock(&d->queue_lock);
		struct bdfs_job *j;
		TAILQ_FOREACH(j, &d->job_queue, entry) queue_depth++;
		pthread_mutex_unlock(&d->queue_lock);

		uint64_t total_demotes = 0;
		time_t last_scan = 0;
		if (d->policy) {
			total_demotes = d->policy->total_demotes;
			last_scan     = d->policy->last_scan_time;
		}
		snprintf(resp, sizeof(resp),
			 "{\"status\":0,\"data\":{"
			 "\"workers\":%d,"
			 "\"queue_depth\":%d,"
			 "\"active_mounts\":%d,"
			 "\"policy_demotes\":%" PRIu64 ","
			 "\"policy_last_scan\":%lld"
			 "}}\n",
			 d->worker_count, queue_depth,
			 bdfs_mount_count(d),
			 (unsigned long long)total_demotes,
			 (long long)last_scan);

	} else if (strstr(req, "\"policy-add\"")) {
		/*
		 * Parse key fields from the JSON request.
		 * Format: {"cmd":"policy-add","args":{...}}
		 */
		/* cppcheck-suppress uninitvar -- all fields set via memset+explicit assigns below */
		struct bdfs_policy_rule rule;
		memset(&rule, 0, sizeof(rule));
		rule.compression = BDFS_COMPRESS_ZSTD;

		/* Extract partition UUID */
		char *p = strstr(req, "\"partition\":\"");
		if (p) {
			p += strlen("\"partition\":\"");
			char uuid_str[37] = {0};
			strncpy(uuid_str, p, 36);
			/* bdfs_str_to_uuid not available here; store raw */
			/* In production use a real JSON parser */
		}

		/* Extract age_days */
		p = strstr(req, "\"age_days\":");
		if (p) rule.age_days = (uint32_t)atoi(p + strlen("\"age_days\":"));

		/* Extract min_size_bytes */
		p = strstr(req, "\"min_size_bytes\":");
		if (p) rule.min_size_bytes =
			(uint64_t)strtoull(p + strlen("\"min_size_bytes\":"),
					   NULL, 10);

		/* Extract name_pattern */
		p = strstr(req, "\"name_pattern\":\"");
		if (p) {
			p += strlen("\"name_pattern\":\"");
			char *end = strchr(p, '"');
			if (end) {
				size_t len = (size_t)(end - p);
				if (len >= sizeof(rule.name_pattern))
					len = sizeof(rule.name_pattern) - 1;
				strncpy(rule.name_pattern, p, len);
			}
		}

		rule.readonly           = !!strstr(req, "\"readonly\":true");
		rule.delete_after_demote = !!strstr(req, "\"delete_after_demote\":true");
		rule.enabled            = true;

		if (d->policy && rule.age_days > 0) {
			uint64_t id = bdfs_policy_add_rule(d->policy, &rule);
			snprintf(resp, sizeof(resp),
				 "{\"status\":0,\"data\":{\"rule_id\":%" PRIu64 "}}\n",
				 (unsigned long long)id);
		} else {
			snprintf(resp, sizeof(resp),
				 "{\"status\":-22,\"error\":"
				 "\"invalid rule or policy engine not running\"}\n");
		}

	} else if (strstr(req, "\"policy-remove\"")) {
		uint64_t rule_id = 0;
		char *p = strstr(req, "\"rule_id\":");
		if (p) rule_id = (uint64_t)strtoull(
				p + strlen("\"rule_id\":"), NULL, 10);

		if (d->policy && rule_id > 0) {
			int r = bdfs_policy_remove_rule(d->policy, rule_id);
			snprintf(resp, sizeof(resp),
				 "{\"status\":%d}\n", r);
		} else {
			snprintf(resp, sizeof(resp),
				 "{\"status\":-22,\"error\":\"invalid rule_id\"}\n");
		}

	} else if (strstr(req, "\"policy-list\"")) {
		if (d->policy) {
			struct bdfs_policy_rule rules[64];
			uint32_t count = 0;
			bdfs_policy_list_rules(d->policy, rules, 64, &count);
			char *pos = resp;
			size_t rem = sizeof(resp);
			int written = snprintf(pos, rem,
				"{\"status\":0,\"data\":{\"rules\":[");
			pos += written; rem -= written;
			for (uint32_t i = 0; i < count && rem > 2; i++) {
				written = snprintf(pos, rem,
					"%s{\"id\":%" PRIu64 ",\"age_days\":%u,"
					"\"pattern\":\"%s\","
					"\"compression\":\"%s\","
					"\"delete_after\":%s,"
					"\"enabled\":%s}",
					i ? "," : "",
					(unsigned long long)rules[i].rule_id,
					rules[i].age_days,
					rules[i].name_pattern,
					/* compression name not available here */
					"zstd",
					rules[i].delete_after_demote ? "true":"false",
					rules[i].enabled ? "true" : "false");
				pos += written; rem -= written;
			}
			snprintf(pos, rem, "]}}\n");
		} else {
			snprintf(resp, sizeof(resp),
				 "{\"status\":0,\"data\":{\"rules\":[]}}\n");
		}

	} else if (strstr(req, "\"policy-scan\"")) {
		if (d->policy) {
			int demoted = bdfs_policy_scan(d->policy);
			snprintf(resp, sizeof(resp),
				 "{\"status\":0,\"data\":"
				 "{\"demotes_queued\":%d}}\n", demoted);
		} else {
			snprintf(resp, sizeof(resp),
				 "{\"status\":-1,\"error\":"
				 "\"policy engine not running\"}\n");
		}

	} else if (strstr(req, "\"cmd\":\"workspace_shutdown\"")) {
		char ws_path[BDFS_PATH_MAX]    = {0};
		char reason_str[32]            = {0};
		char compression_str[32]       = {0};
		char image_path[BDFS_PATH_MAX] = {0};
		int  prune_keep = int_field(req, "prune_keep");

		str_field(req, "workspace_path", ws_path,         sizeof(ws_path));
		str_field(req, "reason",         reason_str,      sizeof(reason_str));
		str_field(req, "compression",    compression_str, sizeof(compression_str));
		str_field(req, "image_path",     image_path,      sizeof(image_path));

		if (!ws_path[0]) {
			snprintf(resp, sizeof(resp),
				 "{\"status\":-22,\"error\":"
				 "\"workspace_path is required\"}\n");
			goto send;
		}

		uint32_t reason_code;
		if (strcmp(reason_str, "pause") == 0)
			reason_code = BDFS_WS_SHUTDOWN_PAUSE;
		else if (strcmp(reason_str, "delete") == 0)
			reason_code = BDFS_WS_SHUTDOWN_DELETE;
		else
			reason_code = BDFS_WS_SHUTDOWN_STOP;

		uint32_t comp = BDFS_COMPRESS_ZSTD;
		if (strcmp(compression_str, "lzma")   == 0) comp = BDFS_COMPRESS_LZMA;
		else if (strcmp(compression_str, "lz4")    == 0) comp = BDFS_COMPRESS_LZ4;
		else if (strcmp(compression_str, "brotli") == 0) comp = BDFS_COMPRESS_BROTLI;
		else if (strcmp(compression_str, "none")   == 0) comp = BDFS_COMPRESS_NONE;

		struct bdfs_job *job = bdfs_job_alloc(BDFS_JOB_WORKSPACE_SHUTDOWN);
		if (!job) {
			snprintf(resp, sizeof(resp),
				 "{\"status\":-12,\"error\":\"out of memory\"}\n");
			goto send;
		}

		strncpy(job->workspace_shutdown.workspace_path,
			ws_path, BDFS_PATH_MAX - 1);
		strncpy(job->workspace_shutdown.image_path,
			image_path, BDFS_PATH_MAX - 1);
		job->workspace_shutdown.reason      = reason_code;
		job->workspace_shutdown.compression = comp;
		job->workspace_shutdown.prune_keep  =
			(uint32_t)(prune_keep > 0 ? prune_keep : 0);

		int r = bdfs_daemon_enqueue(d, job);
		if (r == 0)
			snprintf(resp, sizeof(resp),
				 "{\"status\":\"ok\",\"data\":{"
				 "\"workspace_path\":\"%s\","
				 "\"reason\":\"%s\"}}\n",
				 ws_path,
				 reason_str[0] ? reason_str : "stop");
		else
			snprintf(resp, sizeof(resp),
				 "{\"status\":%d,\"error\":"
				 "\"enqueue failed\"}\n", r);

	} else if (strstr(req, "\"cmd\":\"ping\"") ||
		   strstr(req, "\"ping\"")) {
		snprintf(resp, sizeof(resp), "{\"status\":\"ok\",\"data\":\"pong\"}\n");

	} else {
		status = -ENOSYS;
		snprintf(resp, sizeof(resp),
			 "{\"status\":%d,\"error\":\"unknown command\"}\n",
			 status);
	}

send:
	send(client_fd, resp, strlen(resp), MSG_NOSIGNAL);

out:
	close(client_fd);
}

void bdfs_socket_loop(struct bdfs_daemon *d)
{
	int client_fd;

	client_fd = accept4(d->sock_fd, NULL, NULL,
			    SOCK_CLOEXEC | SOCK_NONBLOCK);
	if (client_fd < 0) {
		if (errno != EAGAIN && errno != EWOULDBLOCK)
			syslog(LOG_ERR, "bdfs: accept: %m");
		return;
	}

	bdfs_handle_client(d, client_fd);
}
