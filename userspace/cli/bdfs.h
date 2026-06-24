/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * bdfs.h - CLI tool internal declarations
 */

#ifndef _BDFS_CLI_H
#define _BDFS_CLI_H

#include <stdint.h>
#include <stdbool.h>
#include "../../include/uapi/bdfs_ioctl.h"

#define BDFS_CLI_VERSION  "1.0.0"

/* Global CLI context */
struct bdfs_cli {
	int     ctl_fd;             /* /dev/bdfs_ctl */
	int     sock_fd;            /* daemon unix socket (optional) */
	bool    verbose;
	bool    json_output;
	bool    no_color;
	char    ctl_device[256];
	char    socket_path[256];
};

/* Subcommand handler signature */
typedef int (*bdfs_cmd_fn)(struct bdfs_cli *cli, int argc, char *argv[]);

struct bdfs_command {
	const char     *name;
	const char     *summary;
	const char     *usage;
	bdfs_cmd_fn     fn;
};

/* ── Subcommand groups ─────────────────────────────────────────────────── */

/* partition subcommands */
int cmd_partition_add(struct bdfs_cli *cli, int argc, char *argv[]);
int cmd_partition_remove(struct bdfs_cli *cli, int argc, char *argv[]);
int cmd_partition_list(struct bdfs_cli *cli, int argc, char *argv[]);
int cmd_partition_show(struct bdfs_cli *cli, int argc, char *argv[]);

/* export/import */
int cmd_export(struct bdfs_cli *cli, int argc, char *argv[]);
int cmd_import(struct bdfs_cli *cli, int argc, char *argv[]);

/* mount/umount */
int cmd_mount(struct bdfs_cli *cli, int argc, char *argv[]);
int cmd_umount(struct bdfs_cli *cli, int argc, char *argv[]);

/* snapshot */
int cmd_snapshot(struct bdfs_cli *cli, int argc, char *argv[]);

/* promote / demote (blend layer) */
int cmd_promote(struct bdfs_cli *cli, int argc, char *argv[]);
int cmd_demote(struct bdfs_cli *cli, int argc, char *argv[]);

/* fetch — restore workspace from IPFS CID */
int cmd_fetch(struct bdfs_cli *cli, int argc, char *argv[]);

/* blend mount/umount */
int cmd_blend_mount(struct bdfs_cli *cli, int argc, char *argv[]);
int cmd_blend_umount(struct bdfs_cli *cli, int argc, char *argv[]);

/* status */
int cmd_status(struct bdfs_cli *cli, int argc, char *argv[]);

/* verify */
int cmd_verify(struct bdfs_cli *cli, int argc, char *argv[]);

/* policy subcommands */
int cmd_policy_add(struct bdfs_cli *cli, int argc, char *argv[]);
int cmd_policy_remove(struct bdfs_cli *cli, int argc, char *argv[]);
int cmd_policy_list(struct bdfs_cli *cli, int argc, char *argv[]);
int cmd_policy_scan(struct bdfs_cli *cli, int argc, char *argv[]);

/* ── Helpers ───────────────────────────────────────────────────────────── */

int  bdfs_cli_open_ctl(struct bdfs_cli *cli);
void bdfs_cli_close(struct bdfs_cli *cli);

/* Output helpers */
void bdfs_print_partition(const struct bdfs_partition *p, bool json);
void bdfs_print_image(const struct bdfs_dwarfs_image *img, bool json);
void bdfs_print_subvol(const struct bdfs_btrfs_subvol *sv, bool json);

/* UUID helpers */
void bdfs_uuid_to_str(const uint8_t uuid[16], char out[37]);
int  bdfs_str_to_uuid(const char *str, uint8_t uuid[16]);

/* Compression name ↔ enum */
const char *bdfs_compression_name(uint32_t c);
uint32_t    bdfs_compression_from_name(const char *name);

/* Error printing */
void bdfs_err(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void bdfs_info(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

/* autosnap subcommand group */
int cmd_autosnap(struct bdfs_cli *cli, int argc, char *argv[]);

#endif /* _BDFS_CLI_H */
